##
# v2/router.tcl - the route table of /api/v2 (staged SP001, T138)
#
#   POST /api/v2/rpc        v2/rpc.tcl       v2_rpc_handle        (dispatcher)
#   POST /api/v2/batch      v2/rpc.tcl       v2_batch_handle      (dispatcher)
#   GET  /api/v2/schema     v2/schema.tcl    v2_schema_handle     (SP032 schema layer)
#   GET  /api/v2/events     v2/events.tcl    v2_events_handle     (IC008, event-push)
#   GET  /api/v2/model      v2/model.tcl     v2_model_handle      (IC009, rega-model)
#   POST|PUT|DELETE /api/v2/programs v2/programs.tcl  v2_programs_handle   (IC010, rega-model)
#   POST /api/v2/rooms      v2/rooms.tcl     v2_rooms_handle      (IC011, rega-model)
#   POST /api/v2/functions  v2/rooms.tcl     v2_functions_handle  (IC011, rega-model)
#   GET|PUT /api/v2/profile v2/profile.tcl   v2_profile_handle    (IC012, user-profile)
#   GET  /api/v2/system     v2/system.tcl    v2_system_handle     (time, sunrise, sunset, firmware version)
#   POST /api/v2/sysvars    v2/sysvars.tcl   v2_sysvars_handle    (changes a system variable)
#   GET|DELETE /api/v2/log  v2/log.tcl       v2_log_handle        (reads and clears the system log)
#   GET|POST|DELETE /api/v2/favourites v2/favourites.tcl v2_favourites_handle (reads and edits the signed-in user's favourite lists)
#   POST /api/v2/messages   v2/messages.tcl  v2_messages_handle   (acknowledges an alarm or service message)
#   GET|POST /api/v2/values v2/values.tcl    v2_values_handle     (reads a device's datapoints, sets one)
#
# The request path is taken from REQUEST_URI (query removed), else SCRIPT_NAME + PATH_INFO.
# The routes answer on /api/v2/... and also on /api/homematic.cgi/v2/...: the second form reaches
# the CGI through lighttpd's PATH_INFO handling, so it works without a lighttpd route for /api/v2.
# A wrong verb is HTTP 405 with the header Allow; an unknown route is HTTP 404; a route whose
# provider file is not installed is also 404 (error 401 "route not found").
# Every route requires the header X-Requested-With (anti-CSRF), a body route also Content-Type
# application/json (executor_checkTransport).
#
# Provider handlers (IC008-IC012) run after the router has chosen the session id: the globals
#   V2_SID    the session id of the request (header, else cookie in cookie_mode)
#   V2_QUERY  the raw QUERY_STRING
# are set, v2_body returns the request body, v2_requireLevel LEVEL ends the request with 400
# (HTTP 401 without a session, 403 for a too low level) unless the session has the level, and the
# handler answers with jsonrpc_response / jsonrpc_error (HTTP status per BD-04).
##

set V2_ROUTES {
  /rpc       {POST rpc.tcl       v2_rpc_handle}
  /batch     {POST rpc.tcl       v2_batch_handle}
  /schema    {GET  schema.tcl    v2_schema_handle}
  /events    {GET  events.tcl    v2_events_handle}
  /model     {GET  model.tcl     v2_model_handle}
  /programs  {{POST PUT DELETE} programs.tcl v2_programs_handle}
  /rooms     {POST rooms.tcl     v2_rooms_handle}
  /functions {POST rooms.tcl     v2_functions_handle}
  /profile   {{GET PUT} profile.tcl v2_profile_handle}
  /system    {GET  system.tcl    v2_system_handle}
  /sysvars   {POST sysvars.tcl   v2_sysvars_handle}
  /log       {{GET DELETE} log.tcl v2_log_handle}
  /favourites {{GET POST DELETE} favourites.tcl v2_favourites_handle}
  /messages  {POST messages.tcl  v2_messages_handle}
  /values    {{GET POST} values.tcl v2_values_handle}
}

##
# Is the request addressed to /api/v2 (or /api/homematic.cgi/v2) ? Returns the path below /api/v2 ("/rpc", "" for the base)
# or -1 for any other request.
##
proc router_v2Path { } {
  global env
  set path ""
  if { [info exists env(REQUEST_URI)] && "" != $env(REQUEST_URI) } then {
    set path [lindex [split $env(REQUEST_URI) "?"] 0]
  } else {
    set script ""
    set info ""
    catch { set script $env(SCRIPT_NAME) }
    catch { set info $env(PATH_INFO) }
    set path "$script$info"
  }
  if { [regexp {^/api/(?:homematic\.cgi/)?v2(/.*)?$} $path -> rest] } then {
    return [string trimright $rest "/"]
  }
  return -1
}

proc v2_body { } {
  global V2_BODY
  if { ![info exists V2_BODY] } then { set V2_BODY [v2_readBody] }
  return $V2_BODY
}

##
# Ends the request unless the session of the request has at least the privilege level (NONE,
# GUEST, USER, ADMIN)
##
proc v2_requireLevel { level } {
  global V2_SID args
  array set m [list LEVEL $level]
  array set args [list _session_id_ $V2_SID]
  array set method [array get m]
  checkPrivilegeLevel method args
}

##
# The numeric privilege level of the session of the request (0 = no or unknown session)
##
proc v2_sessionLevel { } {
  global V2_SID
  array set a [list _session_id_ $V2_SID]
  set upl [string trim [hmscript_runFromFile "eq3/getupl.hms" a]]
  if { ![regexp {^[0-9]+$} $upl] } then { return 0 }
  scan $upl %d upl
  return $upl
}

##
# The ReGa user id of the session of the request ("" if there is none)
##
proc v2_sessionUid { } {
  global V2_SID
  array set a [list _session_id_ $V2_SID]
  set script {var s = system.GetSessionVarStr(_session_id_); if (s) { Write(s.StrValueByIndex(";", 0)); }}
  set uid [string trim [hmscript $script a]]
  if { ![regexp {^[0-9]+$} $uid] } then { return "" }
  return $uid
}

##
# The records of a ReGa script's output: per record a line "{", lines "KEY {value}", a line "}". The output is a Tcl list of
# lists, and when it is well formed that is what comes back, unchanged. A value that holds a brace (a text a user may type
# into a system variable, a name with a "{") breaks the list syntax: one such value must not make the whole answer fail for
# everybody, so the output is then read line by line, where the value of "KEY {value}" is everything up to the last "}" of
# its line (a value may run over several lines). A record is a flat list KEY value KEY value ...
##
proc v2_records { out } {
  if { ![catch { llength $out }] } then {
    set wellFormed 1
    foreach r $out { if { [catch { llength $r } n] || 1 == ($n % 2) } then { set wellFormed 0; break } }
    if { $wellFormed } then { return $out }
  }
  set records {}
  set rec {}
  set inRecord 0
  set open 0
  set key ""
  set val ""
  foreach line [split $out "\n"] {
    set line [string trimright $line "\r"]
    if { $open } then {
      append val "\n$line"
      if { "\}" eq [string index $line end] } then { lappend rec $key [string range $val 0 end-1]; set open 0 }
      continue
    }
    if { "\{" eq $line } then { set rec {}; set inRecord 1; continue }
    if { "\}" eq $line } then { if { $inRecord } then { lappend records $rec }; set inRecord 0; continue }
    if { $inRecord && [regexp {^([A-Za-z][A-Za-z0-9_]*) \{(.*)$} $line -> k rest] } then {
      if { "\}" eq [string index $rest end] } then {
        lappend rec $k [string range $rest 0 end-1]
      } else {
        set key $k; set val $rest; set open 1
      }
    }
  }
  return $records
}

##
# Answers a provider route with a plain JSON document (HTTP 200): the document is not a
# JSON-RPC envelope
##
proc v2_respondJson { json } {
  jsonrpc_v2Headers
  puts "CONTENT-TYPE: application/json; charset=utf-8"
  puts ""
  puts -nonewline [encoding convertto utf-8 [v2_repairUtf8 $json]]
}

##
# ReGa hands its texts over as ISO-8859-1 bytes, but some texts are stored as UTF-8 (a value name such as "nicht
# ausgelöst" written by a newer tool holds the bytes C3 B6): read as ISO-8859-1 they would reach the client as "Ã¶".
# Every well-formed UTF-8 multi-byte sequence is decoded back to its character; ISO-8859-1 text is not touched (an
# umlaut there is a single byte that is not followed by continuation bytes, e.g. "J\xF6rn").
##
proc v2_repairUtf8 { s } {
  if { ![regexp {[\u00c2-\u00f4][\u0080-\u00bf]} $s] } then { return $s }
  set re {[\u00c2-\u00df][\u0080-\u00bf]|[\u00e0-\u00ef][\u0080-\u00bf]{2}|[\u00f0-\u00f4][\u0080-\u00bf]{3}}
  set out ""
  set pos 0
  foreach range [regexp -all -inline -indices -- $re $s] {
    lassign $range from to
    append out [string range $s $pos [expr { $from - 1 }]]
    set seq [string range $s $from $to]
    if { [catch { encoding convertfrom utf-8 $seq } ch] || [string length $ch] != 1 || [scan $ch %c] < 0x80 } then {
      append out $seq
    } else {
      append out $ch
    }
    set pos [expr { $to + 1 }]
  }
  append out [string range $s $pos end]
  return $out
}

proc router_error { status code message {allow ""} } {
  global API_HTTP_STATUS API_EXTRA_HEADERS JSONRPC
  set API_HTTP_STATUS $status
  set JSONRPC(ID_USED) 0
  if { "" != $allow } then { set API_EXTRA_HEADERS [list "Allow: $allow"] }
  jsonrpc_error $code $message
}

##
# Serves one /api/v2 request
##
proc router_serve { path } {
  global env V2_ROUTES V2_SID V2_QUERY JSONRPC DOCUMENT_API_DIR

  if { ![dict exists $V2_ROUTES $path] } then { router_error 404 401 "route not found" }
  lassign [dict get $V2_ROUTES $path] verbs file handler

  set verb ""
  catch { set verb $env(REQUEST_METHOD) }
  if { $verb ni $verbs } then {
    router_error 405 405 "method not allowed" [join $verbs ", "]
  }

  set hasBody [expr { $verb in {POST PUT} }]
  executor_checkTransport $hasBody

  # the handler file (the dispatcher's own, or the provider's)
  if { 0 == [llength [info commands $handler]] } then {
    set f [file join $DOCUMENT_API_DIR v2 $file]
    if { ![file exists $f] } then { router_error 404 401 "route not found" }
    uplevel #0 [list source $f]
    if { 0 == [llength [info commands $handler]] } then { router_error 404 401 "route not found" }
  }

  if { "/rpc" ne $path && "/batch" ne $path } then {
    # provider routes have no JSON-RPC request: the answers carry no id
    set JSONRPC(ID_USED) 0
    # the sid decides before the handler runs (401 without or with an unknown session)
    set V2_SID [v2_header X-Session-Id]
    if { "" == $V2_SID && [string is true -strict [api_config cookie_mode false]] } then { set V2_SID [v2_cookie hm_sid] }
    set V2_QUERY ""
    catch { set V2_QUERY $env(QUERY_STRING) }
    # (an unknown session is rejected by v2_requireLevel of the handler: session level 0 = HTTP 401)
    if { "" == $V2_SID } then {
      set ::API_AUTH_STATE nosid
      jsonrpc_error 400 "access denied (session level 0)"
    }
  }
  $handler
}
