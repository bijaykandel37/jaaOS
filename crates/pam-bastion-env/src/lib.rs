//! PAM module for BastionOS dual-password environments — SCAFFOLD ONLY.
//!
//! This crate is intentionally empty of PAM FFI for now. The trusted prototype auth path is
//! `pam_exec.so` calling `packages/bastion-env/bin/bastion-env-pam`; the native C fallback is
//! `packages/bastion-env/pam_module/`. The Rust implementation (via the `pamsm` crate) is to be
//! written on the cloud AFTER the auth design is security-reviewed, preserving the critical
//! contract: return success ONLY on affirmative authentication of the managed user (a stray
//! success for any other case is an auth bypass — see docs/03-phase2-dual-env.md §4.1).
//!
//! Build target: `cdylib` -> `libpam_bastion_env.so`, installed as `pam_bastion_env.so`.

/// Placeholder so the cdylib builds cleanly before the PAM entry points are implemented.
/// Replace with `pamsm`'s `pam_module!` macro and a `PamServiceModule` impl.
#[doc(hidden)]
pub fn __scaffold() {}
