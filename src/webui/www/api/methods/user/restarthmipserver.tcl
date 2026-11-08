##
# User.restartHmIPServer
# Restarts the HmIP server in the background (staged SP034, ADMIN only).
#
# The command line is fixed (no request data); one syslog line records correlation id, method
# and user id. The answer is true immediately (the restart runs detached).
#
# Return value: [bool] true
##

# admin_audit is defined once in eq3/admin_audit.tcl (sourced by the dispatcher)

admin_audit "restart HmIP server"

exec -- /usr/bin/monit restart HMIPServer >/dev/null &

jsonrpc_response true
