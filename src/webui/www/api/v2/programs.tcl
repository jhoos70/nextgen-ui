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
#   GET    ?id=<id>                                the logic of a program, decoded: its rules (if / else if / else), the condition
#                             groups of each with the single conditions (a device datapoint, a system variable or a time module)
#                             and the actions (set a datapoint, set a system variable, run a script) with their delay. READ ONLY.
#                             {"id","name",...,"rules":[{"hasCondition","groups":[{"op","conditions":[...]}],"stopDelays","actions":[...]}]}
#                             The numbers are ReGa's own codes (see the client, program-logic.ts); free text (names, scripts) is
#                             escaped by the ReGa script (\\ \o \c \n) so that braces and line breaks cannot break the answer.
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

##
# The fixed script that reads the logic of a program: one line per rule, condition, time module, destinations and
# destination. The id is the variable progId. Free text is escaped (backslash, braces, line breaks) so that every line is a
# well formed Tcl list whatever a name or a script holds.
##
set PROGRAM_LOGIC_SCRIPT {
  string i;
  foreach(i, dom.GetObject(ID_PROGRAMS).EnumIDs())
  {
    if (i == progId)
    {
      object p = dom.GetObject(i);
      if (p)
      {
        object r = p.Rule();
        integer ri = 0;
        while (r)
        {
          WriteLine("RULE IDX {" # ri # "} HASCOND {" # r.ElseIfFlag() # "}");
          integer nc = r.RuleConditions().Count();
          if (nc > 0)
          {
            string ci;
            foreach (ci, system.GenerateEnum(0, nc - 1))
            {
              object c = r.RuleCondition(ci);
              if (c)
              {
                integer ns = c.CndSingleCount();
                if (ns > 0)
                {
                  string si;
                  foreach (si, system.GenerateEnum(0, ns - 1))
                  {
                    object s = c.CndSingleCondition(si);
                    if (s)
                    {
                      object lv = dom.GetObject(s.LeftVal());
                      object ch = dom.GetObject(s.ConditionChannel());
                      string lvn = ""; string chn = ""; string vt = ""; string un = ""; string v0 = ""; string v1 = ""; string vl = ""; string rv1 = "" # s.RightVal1(); string rv2 = "" # s.RightVal2();
                      if (lv) { lvn = lv.Name(); vt = lv.ValueType() # "/" # lv.ValueSubType(); un = lv.ValueUnit(); v0 = lv.ValueName0(); v1 = lv.ValueName1(); vl = lv.ValueList(); }
                      if (ch) { chn = ch.Name(); }
                      lvn = lvn.Replace("\\", "\\\\"); lvn = lvn.Replace("{", "\\o"); lvn = lvn.Replace("}", "\\c"); lvn = lvn.Replace("\r", ""); lvn = lvn.Replace("\n", "\\n");
                      chn = chn.Replace("\\", "\\\\"); chn = chn.Replace("{", "\\o"); chn = chn.Replace("}", "\\c"); chn = chn.Replace("\r", ""); chn = chn.Replace("\n", "\\n");
                      un = un.Replace("\\", "\\\\"); un = un.Replace("{", "\\o"); un = un.Replace("}", "\\c"); un = un.Replace("\r", ""); un = un.Replace("\n", "\\n");
                      v0 = v0.Replace("\\", "\\\\"); v0 = v0.Replace("{", "\\o"); v0 = v0.Replace("}", "\\c"); v0 = v0.Replace("\r", ""); v0 = v0.Replace("\n", "\\n");
                      v1 = v1.Replace("\\", "\\\\"); v1 = v1.Replace("{", "\\o"); v1 = v1.Replace("}", "\\c"); v1 = v1.Replace("\r", ""); v1 = v1.Replace("\n", "\\n");
                      vl = vl.Replace("\\", "\\\\"); vl = vl.Replace("{", "\\o"); vl = vl.Replace("}", "\\c"); vl = vl.Replace("\r", ""); vl = vl.Replace("\n", "\\n");
                      rv1 = rv1.Replace("\\", "\\\\"); rv1 = rv1.Replace("{", "\\o"); rv1 = rv1.Replace("}", "\\c"); rv1 = rv1.Replace("\r", ""); rv1 = rv1.Replace("\n", "\\n");
                      rv2 = rv2.Replace("\\", "\\\\"); rv2 = rv2.Replace("{", "\\o"); rv2 = rv2.Replace("}", "\\c"); rv2 = rv2.Replace("\r", ""); rv2 = rv2.Replace("\n", "\\n");
                      WriteLine("COND G {" # ci # "} GOP {" # c.CndOperatorType() # "} S {" # si # "} SOP {" # s.OperatorType() # "} LT {" # s.LeftValType() # "} LV {" # s.LeftVal() # "} CH {" # s.ConditionChannel() # "} CT {" # s.ConditionType() # "} CT2 {" # s.ConditionType2() # "} RT1 {" # s.RightVal1ValType() # "} RV1 {" # rv1 # "} RT2 {" # s.RightVal2ValType() # "} RV2 {" # rv2 # "} LVN {" # lvn # "} CHN {" # chn # "} VT {" # vt # "} UNIT {" # un # "} VN0 {" # v0 # "} VN1 {" # v1 # "} VL {" # vl # "}");
                      if (s.LeftValType() == ivtCurrentDate)
                      {
                        object tm = dom.GetObject(s.RightVal1());
                        if (tm) { WriteLine("TIME TT {" # tm.TimerType() # "} SOT {" # tm.SunOffsetType() # "} SEC {" # tm.TimeSeconds() # "} DUR {" # tm.CalDuration() # "} TIME {" # tm.Time() # "} BEGIN {" # tm.Begin() # "} END {" # tm.End() # "} REP {" # tm.CalRepetitionCount() # "}"); }
                      }
                    }
                  }
                }
              }
            }
          }
          object d = r.RuleDestination();
          if (d)
          {
            integer nd = d.DestSingleCount();
            WriteLine("DESTS BOR {" # d.BreakOnRestart() # "} COUNT {" # nd # "}");
            if (nd > 0)
            {
              string di;
              foreach (di, system.GenerateEnum(0, nd - 1))
              {
                object sd = d.DestSingleDestination(di);
                if (sd)
                {
                  object dch = dom.GetObject(sd.DestinationChannel());
                  object ddp = dom.GetObject(sd.DestinationDP());
                  string dchn = ""; string ddpn = ""; string dvt = ""; string dv = "" # sd.DestinationValue(); string dvp = "" # sd.DestinationValueParam();
                  if (dch) { dchn = dch.Name(); }
                  if (ddp) { ddpn = ddp.Name(); dvt = ddp.ValueType() # "/" # ddp.ValueSubType(); }
                  dchn = dchn.Replace("\\", "\\\\"); dchn = dchn.Replace("{", "\\o"); dchn = dchn.Replace("}", "\\c"); dchn = dchn.Replace("\r", ""); dchn = dchn.Replace("\n", "\\n");
                  ddpn = ddpn.Replace("\\", "\\\\"); ddpn = ddpn.Replace("{", "\\o"); ddpn = ddpn.Replace("}", "\\c"); ddpn = ddpn.Replace("\r", ""); ddpn = ddpn.Replace("\n", "\\n");
                  dv = dv.Replace("\\", "\\\\"); dv = dv.Replace("{", "\\o"); dv = dv.Replace("}", "\\c"); dv = dv.Replace("\r", ""); dv = dv.Replace("\n", "\\n");
                  dvp = dvp.Replace("\\", "\\\\"); dvp = dvp.Replace("{", "\\o"); dvp = dvp.Replace("}", "\\c"); dvp = dvp.Replace("\r", ""); dvp = dvp.Replace("\n", "\\n");
                  WriteLine("DEST P {" # sd.DestinationParam() # "} VT {" # sd.DestinationValueType() # "} VPT {" # sd.DestinationValueParamType() # "} V {" # dv # "} VP {" # dvp # "} CH {" # sd.DestinationChannel() # "} DP {" # sd.DestinationDP() # "} CHN {" # dchn # "} DPN {" # ddpn # "} DPT {" # dvt # "}");
                }
              }
            }
          }
          r = r.RuleSubRule();
          ri = ri + 1;
        }
        WriteLine("END DONE {true}");
      }
    }
  }
}

proc programs_unescape { s } {
  return [string map [list "\\\\" "\\" "\\o" "\{" "\\c" "\}" "\\n" "\n"] $s]
}

proc programs_num { v } {
  if { [regexp {^-?[0-9]{1,12}$} $v] } then { return $v }
  return 0
}

proc programs_bool { v } { return [expr { [string is true -strict $v] ? "true" : "false" }] }

##
# The logic of a program as JSON (see the header). "" = ReGa did not answer.
##
proc programs_logic { id } {
  global PROGRAM_LOGIC_SCRIPT
  array set a [list progId $id]
  set out ""
  if { [catch { set out [hmscript $PROGRAM_LOGIC_SCRIPT a] }] } then { return "" }
  set rules {}
  set rule {}
  set groups {}
  set group {}
  set groupId ""
  set groupOp 0
  set done 0
  set haveRule 0
  foreach line [split $out "\n"] {
    set line [string trim $line]
    if { "" == $line || [catch { llength $line }] } then { continue }
    set tag [lindex $line 0]
    array unset f
    if { [catch { array set f [lrange $line 1 end] }] } then { continue }
    switch -- $tag {
      RULE {
        if { $haveRule } then { lappend rules [programs_closeRule $rule $groups $group $groupOp] }
        set haveRule 1
        set rule [list hasCondition [programs_bool $f(HASCOND)] stopDelays false actions {}]
        set groups {}
        set group {}
        set groupId ""
      }
      COND {
        if { $groupId ne "" && $groupId ne $f(G) } then { lappend groups [list op $groupOp conditions $group]; set group {} }
        set groupId $f(G)
        set groupOp $f(GOP)
        set kind unknown
        if { 18 == $f(LT) } then { set kind device } elseif { 19 == $f(LT) } then { set kind sysvar } elseif { 24 == $f(LT) } then { set kind time }
        foreach k {VT UNIT VN0 VN1 VL LVN CHN RV1 RV2} { set f($k) [programs_unescape $f($k)] }
        # the left value of a time condition is a timestamp, not an object
        set lv $f(LV)
        if { "time" eq $kind } then { set lv "" }
        lappend group [list op $f(SOP) kind $kind objectId $lv objectName $f(LVN) channelId $f(CH) channelName $f(CHN) \
          valueType $f(VT) unit $f(UNIT) valueName0 $f(VN0) valueName1 $f(VN1) valueList $f(VL) \
          test [programs_num $f(CT)] trigger [programs_num $f(CT2)] rightType [programs_num $f(RT1)] right $f(RV1) right2Type [programs_num $f(RT2)] right2 $f(RV2) time {}]
      }
      TIME {
        set last [lindex $group end]
        set last [lreplace $last end end [list timerType [programs_num $f(TT)] sunOffset [programs_num $f(SOT)] seconds [programs_num $f(SEC)] duration [programs_num $f(DUR)] time $f(TIME) begin $f(BEGIN) end $f(END) repetitions [programs_num $f(REP)]]]
        set group [lreplace $group end end $last]
      }
      DESTS {
        dict set rule stopDelays [programs_bool $f(BOR)]
      }
      DEST {
        foreach k {V VP CHN DPN DPT} { set f($k) [programs_unescape $f($k)] }
        set acts [dict get $rule actions]
        lappend acts [list param [programs_num $f(P)] valueType [programs_num $f(VT)] delayType [programs_num $f(VPT)] value $f(V) delay $f(VP) channelId $f(CH) datapointId $f(DP) channelName $f(CHN) datapointName $f(DPN) datapointType $f(DPT)]
        dict set rule actions $acts
      }
      END { set done 1 }
    }
  }
  if { !$done } then { return "" }
  if { $haveRule } then { lappend rules [programs_closeRule $rule $groups $group $groupOp] }
  return "\[[join $rules ,]\]"
}

proc programs_closeRule { rule groups group groupOp } {
  if { [llength $group] } then { lappend groups [list op $groupOp conditions $group] }
  set g {}
  foreach grp $groups {
    set cs {}
    foreach c [dict get $grp conditions] { lappend cs [programs_condJson $c] }
    lappend g "\{\"op\":[json_toString [programs_opName [dict get $grp op]]],\"conditions\":\[[join $cs ,]\]\}"
  }
  set acts {}
  foreach a [dict get $rule actions] { lappend acts [programs_actJson $a] }
  return "\{\"hasCondition\":[dict get $rule hasCondition],\"groups\":\[[join $g ,]\],\"stopDelays\":[dict get $rule stopDelays],\"actions\":\[[join $acts ,]\]\}"
}

proc programs_opName { code } { return [expr { 1 == $code ? "and" : "or" }] }

proc programs_condJson { c } {
  set j "\{\"op\":[json_toString [programs_opName [dict get $c op]]],\"kind\":[json_toString [dict get $c kind]]"
  foreach {k key} {objectId objectId channelId channelId} { append j ",\"$k\":[json_toString [dict get $c $key]]" }
  foreach k {objectName channelName valueType unit valueName0 valueName1 valueList right right2} { append j ",\"$k\":[json_toString [dict get $c $k]]" }
  foreach k {test trigger rightType right2Type} { append j ",\"$k\":[dict get $c $k]" }
  if { [llength [dict get $c time]] } then {
    set t [dict get $c time]
    append j ",\"time\":\{"
    set first 1
    foreach {k v} $t {
      if { !$first } then { append j , }
      set first 0
      if { $k in {timerType sunOffset seconds duration repetitions} } then { append j "\"$k\":$v" } else { append j "\"$k\":[json_toString $v]" }
    }
    append j "\}"
  }
  return "$j\}"
}

proc programs_actJson { a } {
  set j "\{\"param\":[dict get $a param],\"valueType\":[dict get $a valueType],\"delayType\":[dict get $a delayType]"
  foreach k {value delay channelId datapointId channelName datapointName datapointType} { append j ",\"$k\":[json_toString [dict get $a $k]]" }
  return "$j\}"
}

proc programs_detail { } {
  global V2_QUERY
  v2_requireLevel ADMIN
  if { ![regexp {^id=([0-9]{1,10})$} $V2_QUERY -> id] } then { jsonrpc_error 403 "invalid argument (id)" }
  programs_requireManageable $id
  set d [programs_describe $id]
  if { "" == $d } then { programs_failed GET "read program $id" }
  set rules [programs_logic $id]
  if { "" == $rules } then { programs_failed GET "read the logic of program $id" }
  api_syslog daemon.notice "cid=[api_cid] method=GET /api/v2/programs uid=[v2_sessionUid] action=read logic of program $id"
  set base [programs_json $id $d]
  v2_respondJson "[string range $base 0 end-1],\"rules\":$rules\}"
}

proc v2_programs_handle { } {
  global env
  set verb $env(REQUEST_METHOD)
  if { "GET" eq $verb } then { programs_detail; return }
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
