/*
 * SPDX-License-Identifier: PostgreSQL
 * Forbids EXPLAIN when the session user or the current role is a member of wb_explain_guard.role
 * (views_reader by default) and keeps LOG messages, such as debug_print_plan output, from such sessions.
 * A superuser is not a member by itself; an empty value turns the guard off.
 */
#include "postgres.h"

#include "access/xact.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "tcop/utility.h"
#include "utils/acl.h"
#include "utils/guc.h"

PG_MODULE_MAGIC;

static char *guard_role = NULL;
static ProcessUtility_hook_type prev_ProcessUtility = NULL;
static emit_log_hook_type prev_emit_log_hook = NULL;

static Oid	checked_session_role = InvalidOid;
static Oid	checked_user = InvalidOid;
static bool checked_guarded = false;
static bool checking = false;

static bool
is_guarded(Oid session_role, Oid user)
{
	Oid			role;

	if (guard_role[0] == '\0')
		return false;
	role = get_role_oid(guard_role, true);
	return OidIsValid(role) &&
		(is_member_of_role_nosuper(session_role, role) || is_member_of_role_nosuper(user, role));
}

static void
explain_guard_ProcessUtility(PlannedStmt *pstmt, const char *queryString,
							 bool readOnlyTree, ProcessUtilityContext context,
							 ParamListInfo params, QueryEnvironment *queryEnv,
							 DestReceiver *dest, QueryCompletion *qc)
{
	if (IsA(pstmt->utilityStmt, ExplainStmt) && is_guarded(GetSessionUserId(), GetUserId()))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("permission denied to run EXPLAIN")));

	if (prev_ProcessUtility)
		prev_ProcessUtility(pstmt, queryString, readOnlyTree, context,
							params, queryEnv, dest, qc);
	else
		standard_ProcessUtility(pstmt, queryString, readOnlyTree, context,
								params, queryEnv, dest, qc);
}

/* Role membership comes from the catalogs, which are readable only inside a transaction. */
static void
explain_guard_emit_log(ErrorData *edata)
{
	if (edata->output_to_client && edata->elevel < INFO && guard_role[0] != '\0')
	{
		Oid			session_role = GetSessionUserId();
		Oid			user = GetUserId();

		if (IsTransactionState() && !checking)
		{
			checking = true;
			PG_TRY();
			{
				checked_guarded = is_guarded(session_role, user);
				checked_session_role = session_role;
				checked_user = user;
			}
			PG_FINALLY();
			{
				checking = false;
			}
			PG_END_TRY();
		}
		if (session_role != checked_session_role || user != checked_user || checked_guarded)
			edata->output_to_client = false;
	}

	if (prev_emit_log_hook)
		prev_emit_log_hook(edata);
}

void
_PG_init(void)
{
	DefineCustomStringVariable("wb_explain_guard.role",
							   "Members of this role may not run EXPLAIN or receive LOG messages. Empty disables the guard.",
							   NULL,
							   &guard_role,
							   "views_reader",
							   PGC_SIGHUP,
							   0,
							   NULL, NULL, NULL);
	MarkGUCPrefixReserved("wb_explain_guard");

	prev_ProcessUtility = ProcessUtility_hook;
	ProcessUtility_hook = explain_guard_ProcessUtility;
	prev_emit_log_hook = emit_log_hook;
	emit_log_hook = explain_guard_emit_log;
}
