##
# v2/programs.tcl - POST /api/v2/programs: runs a program, or switches it on or off
#
#   {"id","execute":true}     runs the program: the "Action" of the classic status page. USER or higher (GUEST is HTTP 403).
#                             The answer is strict JSON {"id":"1053","executed":true,"lastExecuteTime":"2026-10-31 21:10:00"}
#                             with the time of the last run as ReGa reports it after the run.
#   {"id","active":true|false}  activates or deactivates the program: what the classic "Programs and connections" editor
#                             does (the status page only SHOWS the flag). ADMINISTRATORS only (HTTP 403 for anyone else).
#                             The answer is {"id":"1053","isActive":false}, the flag as ReGa holds it after the change.
#                             NOTE: activating a program makes ReGa check its conditions and the program can RUN AT ONCE (seen
#                             on a restored real CCU: activating "Abwesenheit" ran it and four programs that depend on it);
#                             deactivating runs nothing. A client should ask before it activates.
# Exactly one of "execute" and "active" is given.
#
# Program management (ADMINISTRATORS only, HTTP 403 for anyone else; the classic "Programs and connections" list):
#   POST   {"create":true,"name","description"?}   creates an EMPTY program (no condition, no action), switched off:
#                             {"id","name","description","isActive":false,"isVisible":true,"isOperable":false}
#   POST   {"id","copy":true,"name"}               copies a program under a new name (switched off, whatever the original is)
#   PUT    {"id","name"?,"description"?,"isVisible"?,"isOperable"?}   changes the given fields; the answer holds all four as
#                             ReGa has them afterwards. "isOperable" is the full access of users who are not administrators.
#   DELETE ?id=<id>                                deletes a program; the system's own (internal or unerasable) are refused.
# A name is 1..100 characters without control characters and must not belong to any other ReGa object (HTTP 409, error 404
# "name already in use"); a description is up to 1000 characters. The conditions and actions of a program are not
# editable here. Every create, copy, change and delete is one line in the syslog.
#
# Only a program can be run: the id is looked up in the collection of the programs in both scripts, never as any ReGa
# object. A program that is internal is refused (HTTP 403), a program copy is not found (404), and a user who is not
# an administrator needs the full access right of the program (as the classic status page, which lists only those); a
# program that is internal (the system's own) is neither run nor switched.
# Errors (HTTP status by BD-04): no or unknown session 401, a guest, an internal program or no right 403, unknown id
# 404, a malformed body, id or key 422 (error 403 "invalid argument (<name>)"), a body that is not JSON 400. Every run
# and every switch is one line in the syslog (who, which program).
##

##
# The fixed script that finds a program in the program collection and describes it
##
proc programs_read { id } {
  set script {
    string i;
    foreach(i, dom.GetObject(ID_PROGRAMS).EnumIDs())
    {
      if (i == progId)
      {
        var p = dom.GetObject(i);
        if (p)
        {
          if (p.IsTypeOf(OT_PROGRAM))
          {
            Write("FOUND {true} INTERNAL {" # p.Internal() # "} COPY {" # (p.ProgramCopyID() != ID_ERROR) # "} FULL {" # (p.UserAccessRights(iulOtherThanAdmin) == iarFullAccess) # "}");
          }
        }
      }
    }
  }
  array set a [list progId $id]
  array set s {FOUND false INTERNAL false COPY false FULL false}
  catch { array set s [hmscript $script a] }
  if { ![string is true -strict $s(FOUND)] } then { return "" }
  return [array get s]
}

##
# The fixed script that runs the program and reads the time of its last run back
##
proc programs_execute { id } {
  set script {
    string i;
    foreach(i, dom.GetObject(ID_PROGRAMS).EnumIDs())
    {
      if (i == progId)
      {
        var p = dom.GetObject(i);
        if (p)
        {
          boolean ok = p.ProgramExecute();
          Write("OK {" # ok # "} TIME {" # p.ProgramLastExecuteTime() # "}");
        }
      }
    }
  }
  array set a [list progId $id]
  array set r {}
  catch { array set r [hmscript $script a] }
  if { ![info exists r(OK)] } then { return "" }
  return [array get r]
}

##
# The fixed script that sets the active flag of the program and reads it back; the value comes as the variable newActive
##
proc programs_setActive { id active } {
  set script {
    string i;
    foreach(i, dom.GetObject(ID_PROGRAMS).EnumIDs())
    {
      if (i == progId)
      {
        var p = dom.GetObject(i);
        if (p)
        {
          if (newActive == "true") { p.Active(true); } else { p.Active(false); }
          Write("ACTIVE {" # p.Active() # "}");
        }
      }
    }
  }
  array set a [list progId $id newActive $active]
  array set r {}
  catch { array set r [hmscript $script a] }
  if { ![info exists r(ACTIVE)] } then { return "" }
  return [array get r]
}

set PROGRAM_NAME_MAX 100
set PROGRAM_INFO_MAX 1000

##
# The fixed script that describes a program the way the management routes answer. The id comes as the variable progId.
##
proc programs_describe { id } {
  set script {
    string i;
    foreach(i, dom.GetObject(ID_PROGRAMS).EnumIDs())
    {
      if (i == progId)
      {
        var p = dom.GetObject(i);
        if (p)
        {
          Write("NAME {" # p.Name() # "} INFO {" # p.PrgInfo() # "} ACTIVE {" # p.Active() # "} VISIBLE {" # p.Visible() # "} OPERABLE {" # (p.UserAccessRights(iulOtherThanAdmin) == iarFullAccess) # "} DONE {true}");
        }
      }
    }
  }
  array set a [list progId $id]
  array set d {}
  catch { array set d [hmscript $script a] }
  if { ![info exists d(DONE)] } then { return "" }
  return [array get d]
}

proc programs_json { id d } {
  array set r $d
  return "\{\"id\":[json_toString $id],\"name\":[json_toString $r(NAME)],\"description\":[json_toString $r(INFO)],\"isActive\":[expr { [string is true -strict $r(ACTIVE)] ? "true" : "false" }],\"isVisible\":[expr { [string is true -strict $r(VISIBLE)] ? "true" : "false" }],\"isOperable\":[expr { [string is true -strict $r(OPERABLE)] ? "true" : "false" }]\}"
}

##
# Is the name taken by another ReGa object (of any kind)? "" = the script did not answer.
##
proc programs_nameTaken { name exceptId } {
  set script {
    var o = dom.GetObject(progName);
    string r = "false";
    if (o) { if (o.ID() != progExcept) { r = "true"; } }
    Write("TAKEN {" # r # "} DONE {true}");
  }
  array set a [list progName $name progExcept $exceptId]
  array set t {}
  catch { array set t [hmscript $script a] }
  if { ![info exists t(DONE)] } then { return "" }
  return [string is true -strict $t(TAKEN)]
}

proc programs_checkName { name } {
  global PROGRAM_NAME_MAX
  if { "" == [string trim $name] || $name ne [string trim $name] || [string length $name] > $PROGRAM_NAME_MAX || [regexp {[\u0000-\u001f\u007f]} $name] } then { jsonrpc_error 403 "invalid argument (name)" }
}

proc programs_checkInfo { info } {
  global PROGRAM_INFO_MAX
  if { [string length $info] > $PROGRAM_INFO_MAX || [regexp {[\u0000-\u0008\u000b-\u001f\u007f]} $info] } then { jsonrpc_error 403 "invalid argument (description)" }
}

proc programs_failed { verb what } {
  api_syslog daemon.warning "cid=[api_cid] method=$verb /api/v2/programs uid=[v2_sessionUid] action=$what failed: the CCU did not answer"
  jsonrpc_error 501 "the CCU did not take the change"
}

proc programs_requireFreeName { name exceptId verb what } {
  set taken [programs_nameTaken $name $exceptId]
  if { "" == $taken } then { programs_failed $verb $what }
  if { $taken } then {
    global API_HTTP_STATUS
    set API_HTTP_STATUS 409
    jsonrpc_error 404 "name already in use"
  }
}

##
# The program the management routes work on: found in the program collection, not a copy of the editor, not internal.
# Answers the 404 and 403 itself; returns the properties of programs_read.
##
proc programs_requireManageable { id } {
  set p [programs_read $id]
  array set s [expr { "" == $p ? {COPY false} : $p }]
  if { "" == $p || [string is true -strict $s(COPY)] } then {
    global API_HTTP_STATUS
    set API_HTTP_STATUS 404
    jsonrpc_error 501 "program not found"
  }
  if { [string is true -strict $s(INTERNAL)] } then { jsonrpc_error 400 "access denied (program)" }
  return $p
}

proc programs_create { name info } {
  set script {
    var created = dom.CreateObject(OT_PROGRAM);
    if (created)
    {
      created.Name(progName);
      created.PrgInfo(progInfo);
      created.Active(false);
      boolean added = dom.GetObject(ID_PROGRAMS).Add(created.ID());
      Write("ID {" # created.ID() # "} ADDED {" # added # "}");
    }
  }
  array set a [list progName $name progInfo $info]
  array set r {}
  catch { array set r [hmscript $script a] }
  if { ![info exists r(ID)] || ![string is true -strict $r(ADDED)] } then { return "" }
  return $r(ID)
}

proc programs_copy { id name } {
  set script {
    string i;
    foreach(i, dom.GetObject(ID_PROGRAMS).EnumIDs())
    {
      if (i == progId)
      {
        var p = dom.GetObject(i);
        if (p)
        {
          var c = p.ProgramCopyTo();
          if (c)
          {
            c.ProgramCopyID(ID_ERROR);
            c.Name(progName);
            c.ProgramUpdate();
            c.Active(false);
            Write("ID {" # c.ID() # "}");
          }
        }
      }
    }
  }
  array set a [list progId $id progName $name]
  array set r {}
  catch { array set r [hmscript $script a] }
  if { ![info exists r(ID)] } then { return "" }
  return $r(ID)
}

proc programs_update { id fields } {
  set script {
    string i;
    foreach(i, dom.GetObject(ID_PROGRAMS).EnumIDs())
    {
      if (i == progId)
      {
        var p = dom.GetObject(i);
        if (p)
        {
          if (setName == "true") { p.Name(newName); }
          if (setInfo == "true") { p.PrgInfo(newInfo); }
          if (setVisible == "true") { if (newVisible == "true") { p.Visible(true); } else { p.Visible(false); } }
          if (setOperable == "true") { if (newOperable == "true") { p.UserAccessRights(iulOtherThanAdmin, iarFullAccess); } else { p.UserAccessRights(iulOtherThanAdmin, iarRead); } }
          Write("DONE {true}");
        }
      }
    }
  }
  array set f $fields
  array set a [list progId $id setName [info exists f(name)] newName [expr { [info exists f(name)] ? $f(name) : "" }] \
    setInfo [info exists f(description)] newInfo [expr { [info exists f(description)] ? $f(description) : "" }] \
    setVisible [info exists f(isVisible)] newVisible [expr { [info exists f(isVisible)] ? $f(isVisible) : "" }] \
    setOperable [info exists f(isOperable)] newOperable [expr { [info exists f(isOperable)] ? $f(isOperable) : "" }]]
  foreach k {setName setInfo setVisible setOperable} { set a($k) [expr { $a($k) ? "true" : "false" }] }
  array set r {}
  catch { array set r [hmscript $script a] }
  return [info exists r(DONE)]
}

proc programs_delete { id } {
  set script {
    string i;
    foreach(i, dom.GetObject(ID_PROGRAMS).EnumIDs())
    {
      if (i == progId)
      {
        var p = dom.GetObject(i);
        if (p)
        {
          if (!p.Unerasable())
          {
            Write("DELETED {" # dom.DeleteObject(p.ID()) # "}");
          }
          else { Write("DELETED {false}"); }
        }
      }
    }
  }
  array set a [list progId $id]
  array set r {DELETED false}
  catch { array set r [hmscript $script a] }
  return [string is true -strict $r(DELETED)]
}

proc programs_parseBody { allowed } {
  set text [v2_body]
  if { [catch { array set body [json_parseObject text] } cause] } then {
    jsonrpc_error 100 "invalid request ($cause)"
  }
  foreach key [array names body] {
    if { $key ni $allowed } then { jsonrpc_error 403 "invalid argument ([regsub -all {[^A-Za-z0-9_.-]} [string range $key 0 39] _])" }
  }
  return [array get body]
}

proc programs_manage { verb } {
  global env V2_QUERY
  v2_requireLevel ADMIN
  set uid [v2_sessionUid]

  if { "DELETE" eq $verb } then {
    if { ![regexp {^id=([0-9]{1,10})$} $V2_QUERY -> id] } then { jsonrpc_error 403 "invalid argument (id)" }
    programs_requireManageable $id
    if { ![programs_delete $id] } then { programs_failed DELETE "delete program $id" }
    api_syslog daemon.notice "cid=[api_cid] method=DELETE /api/v2/programs uid=$uid action=delete program $id"
    v2_respondJson "\{\"id\":[json_toString $id],\"deleted\":true\}"
    return
  }

  if { "PUT" eq $verb } then {
    array set body [programs_parseBody {id name description isVisible isOperable}]
    if { ![info exists body(id)] || ![regexp {^[0-9]{1,10}$} $body(id)] } then { jsonrpc_error 403 "invalid argument (id)" }
    set fields {}
    if { [info exists body(name)] } then { programs_checkName $body(name); lappend fields name $body(name) }
    if { [info exists body(description)] } then { programs_checkInfo $body(description); lappend fields description $body(description) }
    foreach k {isVisible isOperable} {
      if { [info exists body($k)] } then {
        if { $body($k) ne "true" && $body($k) ne "false" } then { jsonrpc_error 403 "invalid argument ($k)" }
        lappend fields $k $body($k)
      }
    }
    if { 0 == [llength $fields] } then { jsonrpc_error 403 "invalid argument (nothing to change)" }
    programs_requireManageable $body(id)
    if { [info exists body(name)] } then { programs_requireFreeName $body(name) $body(id) PUT "change program $body(id)" }
    if { ![programs_update $body(id) $fields] } then { programs_failed PUT "change program $body(id)" }
    set d [programs_describe $body(id)]
    if { "" == $d } then { programs_failed PUT "change program $body(id)" }
    api_syslog daemon.notice "cid=[api_cid] method=PUT /api/v2/programs uid=$uid action=change program $body(id) fields=[lsort [dict keys $fields]]"
    v2_respondJson [programs_json $body(id) $d]
    return
  }

  # POST: create or copy
  array set body [programs_parseBody {create copy id name description}]
  if { [info exists body(create)] } then {
    if { "true" ne $body(create) || [info exists body(id)] || [info exists body(copy)] } then { jsonrpc_error 403 "invalid argument (create)" }
    if { ![info exists body(name)] } then { jsonrpc_error 403 "invalid argument (name)" }
    programs_checkName $body(name)
    set info ""
    if { [info exists body(description)] } then { set info $body(description) }
    programs_checkInfo $info
    programs_requireFreeName $body(name) 0 POST "create program"
    set id [programs_create $body(name) $info]
    if { "" == $id } then { programs_failed POST "create program" }
    api_syslog daemon.notice "cid=[api_cid] method=POST /api/v2/programs uid=$uid action=create program $id"
  } else {
    if { ![info exists body(copy)] || "true" ne $body(copy) || [info exists body(description)] } then { jsonrpc_error 403 "invalid argument (copy)" }
    if { ![info exists body(id)] || ![regexp {^[0-9]{1,10}$} $body(id)] } then { jsonrpc_error 403 "invalid argument (id)" }
    if { ![info exists body(name)] } then { jsonrpc_error 403 "invalid argument (name)" }
    programs_checkName $body(name)
    programs_requireManageable $body(id)
    programs_requireFreeName $body(name) 0 POST "copy program $body(id)"
    set id [programs_copy $body(id) $body(name)]
    if { "" == $id } then { programs_failed POST "copy program $body(id)" }
    api_syslog daemon.notice "cid=[api_cid] method=POST /api/v2/programs uid=$uid action=copy program $body(id) to $id"
  }
  set d [programs_describe $id]
  if { "" == $d } then { programs_failed POST "describe program $id" }
  v2_respondJson [programs_json $id $d]
}

proc v2_programs_handle { } {
  global env
  set verb $env(REQUEST_METHOD)
  if { "POST" ne $verb } then { programs_manage $verb; return }
  v2_requireLevel USER

  set text [v2_body]
  if { [catch { array set peek [json_parseObject text] } cause] } then {
    jsonrpc_error 100 "invalid request ($cause)"
  }
  if { [info exists peek(create)] || [info exists peek(copy)] } then { programs_manage POST; return }
  array set body [array get peek]
  foreach key [array names body] {
    if { $key ni {id execute active} } then { jsonrpc_error 403 "invalid argument ([regsub -all {[^A-Za-z0-9_.-]} [string range $key 0 39] _])" }
  }
  if { ![info exists body(id)] || ![regexp {^[0-9]{1,10}$} $body(id)] } then { jsonrpc_error 403 "invalid argument (id)" }
  set switching [info exists body(active)]
  if { $switching && [info exists body(execute)] } then { jsonrpc_error 403 "invalid argument (execute)" }
  if { $switching } then {
    if { $body(active) ne "true" && $body(active) ne "false" } then { jsonrpc_error 403 "invalid argument (active)" }
    # switching a program on or off is the editor's job: administrators only (the status page only shows the flag)
    v2_requireLevel ADMIN
  } elseif { ![info exists body(execute)] || "true" ne $body(execute) } then {
    jsonrpc_error 403 "invalid argument (execute)"
  }

  set p [programs_read $body(id)]
  array set s [expr { "" == $p ? {COPY false} : $p }]
  if { "" == $p || [string is true -strict $s(COPY)] } then {
    global API_HTTP_STATUS
    set API_HTTP_STATUS 404
    jsonrpc_error 501 "program not found"
  }
  if { [string is true -strict $s(INTERNAL)] } then { jsonrpc_error 400 "access denied (program)" }
  if { [v2_sessionLevel] < 8 && ![string is true -strict $s(FULL)] } then { jsonrpc_error 400 "access denied (program)" }

  if { $switching } then {
    set switched [programs_setActive $body(id) $body(active)]
    if { "" == $switched } then {
      api_syslog daemon.warning "cid=[api_cid] method=POST /api/v2/programs uid=[v2_sessionUid] action=switch program $body(id) failed: the CCU did not answer"
      jsonrpc_error 501 "the CCU did not take the change"
    }
    array set r $switched
    api_syslog daemon.notice "cid=[api_cid] method=POST /api/v2/programs uid=[v2_sessionUid] action=[expr { $body(active) ? "activate" : "deactivate" }] program $body(id)"
    v2_respondJson "\{\"id\":[json_toString $body(id)],\"isActive\":[expr { [string is true -strict $r(ACTIVE)] ? "true" : "false" }]\}"
    return
  }

  set ran [programs_execute $body(id)]
  if { "" == $ran } then {
    api_syslog daemon.warning "cid=[api_cid] method=POST /api/v2/programs uid=[v2_sessionUid] action=execute program $body(id) failed: the CCU did not answer"
    jsonrpc_error 501 "the CCU did not answer"
  }
  array set r $ran
  api_syslog daemon.notice "cid=[api_cid] method=POST /api/v2/programs uid=[v2_sessionUid] action=execute program $body(id)"
  v2_respondJson "\{\"id\":[json_toString $body(id)],\"executed\":[expr { [string is true -strict $r(OK)] ? "true" : "false" }],\"lastExecuteTime\":[json_toString $r(TIME)]\}"
}
