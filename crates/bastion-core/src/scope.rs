//! IPv4 scope matching — the first real Rust port of a bash spec (Phase 7).
//!
//! Ported from `packages/bastion-scan/bin/bastion-scan` (the `in_cidr` / `hard_denied` /
//! `in_scope` / `target_host` functions). Behaviour must stay identical to that spec and to the
//! cases in `tests/vm/vapt-test.sh`; the unit tests below pin it. Pure and deterministic — no
//! DNS, no I/O — so a hostname is matched on its literal value, exactly as the bash gate does.

/// Parse dotted-quad IPv4 into a `u32`, or `None` if it is not a valid IPv4 literal.
pub fn parse_ipv4(s: &str) -> Option<u32> {
    let mut octets = [0u32; 4];
    let mut n = 0;
    for part in s.split('.') {
        if n == 4 {
            return None; // too many octets
        }
        let v: u32 = part.parse().ok()?;
        if v > 255 || (part.len() > 1 && part.starts_with('0')) {
            return None; // out of range or leading zero
        }
        octets[n] = v;
        n += 1;
    }
    if n != 4 {
        return None;
    }
    Some((octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3])
}

/// Is `ip` inside `cidr`? `cidr` may be `a.b.c.d` (treated as /32) or `a.b.c.d/bits`.
/// Non-IPv4 inputs are never "inside" anything (returns false), matching the bash gate.
pub fn in_cidr(ip: &str, cidr: &str) -> bool {
    let (net, bits) = match cidr.split_once('/') {
        Some((n, b)) => match b.parse::<u32>() {
            Ok(b) if b <= 32 => (n, b),
            _ => return false,
        },
        None => (cidr, 32),
    };
    let (Some(ipi), Some(neti)) = (parse_ipv4(ip), parse_ipv4(net)) else {
        return false;
    };
    let mask: u32 = if bits == 0 { 0 } else { (!0u32) << (32 - bits) };
    (ipi & mask) == (neti & mask)
}

/// Ranges refused even if explicitly scoped (defensive rail). Loopback is intentionally NOT
/// here: self-testing 127.0.0.1 is legitimate, but only if the operator scopes it on purpose.
pub fn hard_denied(ip: &str) -> bool {
    if parse_ipv4(ip).is_none() {
        return false;
    }
    in_cidr(ip, "169.254.0.0/16")   // link-local incl. cloud metadata 169.254.169.254
        || in_cidr(ip, "224.0.0.0/4") // multicast
        || in_cidr(ip, "0.0.0.0/8")   // "this network"
        || ip == "255.255.255.255" // broadcast
}

/// Extract the bare host from an IP / host / URL (strip scheme, path, and `:port`).
pub fn target_host(target: &str) -> &str {
    let t = target.split_once("://").map(|(_, r)| r).unwrap_or(target);
    let t = t.split('/').next().unwrap_or(t);
    t.split(':').next().unwrap_or(t)
}

/// A parsed engagement scope. All matching is literal (no DNS), exactly like the bash gate.
#[derive(Debug, Default, Clone)]
pub struct Scope {
    pub cidrs: Vec<String>,
    pub hosts: Vec<String>,
    pub domains: Vec<String>,
    pub exclude: Vec<String>,
}

impl Scope {
    /// `Ok(())` if the target is in scope and not excluded/denied, else `Err(reason)`.
    /// Exclusions and hard-denied ranges win over any scope entry, matching the spec.
    pub fn allows(&self, target: &str) -> Result<(), String> {
        let host = target_host(target);
        let is_ip = parse_ipv4(host).is_some();

        if hard_denied(host) {
            return Err("hard-denied range".into());
        }
        for x in &self.exclude {
            if is_ip && parse_ipv4(x.split('/').next().unwrap_or(x)).is_some() {
                if in_cidr(host, x) {
                    return Err(format!("in EXCLUDE ({x})"));
                }
            } else if host == x {
                return Err(format!("in EXCLUDE ({x})"));
            }
        }
        if is_ip {
            if self.cidrs.iter().any(|c| in_cidr(host, c)) {
                return Ok(());
            }
            return Err("not in any SCOPE_CIDRS".into());
        }
        if self.hosts.iter().any(|h| h == host) {
            return Ok(());
        }
        for d in &self.domains {
            if host == d || host.ends_with(&format!(".{d}")) {
                return Ok(());
            }
        }
        Err("not in SCOPE_HOSTS/SCOPE_DOMAINS".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scope() -> Scope {
        Scope {
            cidrs: vec!["203.0.113.0/24".into(), "198.51.100.10/32".into()],
            hosts: vec!["app.example.com".into()],
            domains: vec!["example.com".into()],
            exclude: vec!["203.0.113.1".into()],
        }
    }

    #[test]
    fn ipv4_parse_rejects_junk() {
        assert!(parse_ipv4("203.0.113.5").is_some());
        assert!(parse_ipv4("256.0.0.1").is_none());
        assert!(parse_ipv4("10.0.0").is_none());
        assert!(parse_ipv4("10.0.0.1.2").is_none());
        assert!(parse_ipv4("010.0.0.1").is_none()); // leading zero
    }

    #[test]
    fn cidr_membership() {
        assert!(in_cidr("203.0.113.5", "203.0.113.0/24"));
        assert!(!in_cidr("203.0.114.5", "203.0.113.0/24"));
        assert!(in_cidr("198.51.100.10", "198.51.100.10/32"));
        assert!(in_cidr("1.2.3.4", "0.0.0.0/0"));
    }

    #[test]
    fn host_extraction() {
        assert_eq!(
            target_host("https://app.example.com/login?x=1"),
            "app.example.com"
        );
        assert_eq!(target_host("app.example.com:8443"), "app.example.com");
        assert_eq!(target_host("203.0.113.5"), "203.0.113.5");
    }

    #[test]
    fn scope_decisions_match_bash_gate() {
        let s = scope();
        assert!(s.allows("203.0.113.5").is_ok()); // in CIDR
        assert!(s.allows("203.0.114.5").is_err()); // out of CIDR
        assert!(s.allows("app.example.com").is_ok()); // exact host
        assert!(s.allows("sub.example.com").is_ok()); // sub-domain
        assert!(s.allows("evil.com").is_err()); // foreign
        assert!(s.allows("203.0.113.1").is_err()); // excluded (wins over CIDR)
        assert!(s.allows("https://app.example.com/x").is_ok()); // URL host extracted
    }

    #[test]
    fn hard_deny_wins_over_scope() {
        let s = Scope {
            cidrs: vec!["169.254.0.0/16".into()],
            ..Default::default()
        };
        assert_eq!(
            s.allows("169.254.169.254").unwrap_err(),
            "hard-denied range"
        );
    }
}
