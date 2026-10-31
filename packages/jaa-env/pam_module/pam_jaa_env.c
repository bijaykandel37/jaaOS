/*
 * pam_jaa_env.c — SKELETON native PAM module for jaaOS dual-env.
 *
 * NOT AUDITED, NOT THE TRUSTED PATH. The prototype's trusted path is the upstream,
 * audited pam_exec.so calling jaa-env-pam (see docs/03-phase2-dual-env.md §4.1).
 * This native module exists only so a future, security-reviewed native integration has
 * a starting point. For now it simply re-executes the same helper, so behaviour — and
 * the critical "exit 0 only on affirmative auth" contract — stays identical.
 *
 * Build:  make   (needs libpam0g-dev)
 */
#include <security/pam_modules.h>
#include <security/pam_ext.h>

#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

#define HELPER "/usr/lib/jaa-env/bin/jaa-env-pam"

static int run_helper(pam_handle_t *pamh, const char *pam_type, const char *authtok)
{
	const char *user = NULL;
	if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || user == NULL)
		return PAM_AUTH_ERR;

	int pipefd[2] = {-1, -1};
	if (authtok != NULL && pipe(pipefd) != 0)
		return PAM_AUTH_ERR;

	pid_t pid = fork();
	if (pid < 0) {
		if (authtok != NULL) { close(pipefd[0]); close(pipefd[1]); }
		return PAM_AUTH_ERR;
	}

	if (pid == 0) {
		if (authtok != NULL) {
			dup2(pipefd[0], STDIN_FILENO);
			close(pipefd[0]);
			close(pipefd[1]);
		}
		setenv("PAM_TYPE", pam_type, 1);
		setenv("PAM_USER", user, 1);
		const char *svc = NULL;
		if (pam_get_item(pamh, PAM_SERVICE, (const void **)&svc) == PAM_SUCCESS && svc)
			setenv("PAM_SERVICE", svc, 1);
		execl(HELPER, HELPER, (char *)NULL);
		_exit(127);
	}

	if (authtok != NULL) {
		close(pipefd[0]);
		size_t len = strlen(authtok);
		ssize_t w = write(pipefd[1], authtok, len);
		(void)w;
		close(pipefd[1]);
	}

	int status = 0;
	if (waitpid(pid, &status, 0) < 0)
		return PAM_AUTH_ERR;

	return (WIFEXITED(status) && WEXITSTATUS(status) == 0) ? PAM_SUCCESS : PAM_AUTH_ERR;
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
	(void)flags; (void)argc; (void)argv;
	const char *authtok = NULL;
	if (pam_get_authtok(pamh, PAM_AUTHTOK, &authtok, NULL) != PAM_SUCCESS || authtok == NULL)
		return PAM_AUTH_ERR;
	return run_helper(pamh, "auth", authtok);
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
	(void)pamh; (void)flags; (void)argc; (void)argv;
	return PAM_SUCCESS;
}

PAM_EXTERN int pam_sm_acct_mgmt(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
	(void)pamh; (void)flags; (void)argc; (void)argv;
	return PAM_SUCCESS;
}

PAM_EXTERN int pam_sm_open_session(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
	(void)flags; (void)argc; (void)argv;
	return run_helper(pamh, "open_session", NULL);
}

PAM_EXTERN int pam_sm_close_session(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
	(void)flags; (void)argc; (void)argv;
	return run_helper(pamh, "close_session", NULL);
}
