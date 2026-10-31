# Build the (skeleton) native PAM module. Needs: libpam0g-dev build-essential
CC      ?= gcc
CFLAGS  ?= -O2 -fPIC -Wall -Wextra -fstack-protector-strong -D_FORTIFY_SOURCE=2
LDFLAGS ?= -shared
PAM_DIR ?= /lib/x86_64-linux-gnu/security

all: pam_jaa_env.so

pam_jaa_env.so: pam_jaa_env.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $< -lpam

check:
	$(CC) $(CFLAGS) -fsyntax-only pam_jaa_env.c

install: pam_jaa_env.so
	install -Dm0644 pam_jaa_env.so $(DESTDIR)$(PAM_DIR)/pam_jaa_env.so

clean:
	rm -f pam_jaa_env.so

.PHONY: all check install clean
