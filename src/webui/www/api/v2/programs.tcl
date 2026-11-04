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
#   GET    ?targets=conditions                     the same for conditions: datapoints that can be read or report, and variables
#   GET    ?targets=1                              what an action can set: {"datapoints":[...writable ones with their type, range, unit
#                             and list],"variables":[...]} (administrators)
#   GET    ?id=<id>                                the logic of a program, decoded: its rules (if / else if / else), the condition
#                             groups of each with the single conditions (a device datapoint, a system variable or a time module)
#                             and the actions (set a datapoint, set a system variable, run a script) with their delay. READ ONLY.
#                             {"id","name",...,"rules":[{"hasCondition","groups":[{"op","conditions":[...]}],"stopDelays","actions":[...]}]}
#                             The numbers are ReGa's own codes (see the client, program-logic.ts); free text (names, scripts) is
#                             escaped by the ReGa script (\\ \o \c \n) so that braces and line breaks cannot break the answer.
#   PUT    {"id","rule":<index>,"actions":[...],"stopDelays"?}   REPLACES the actions of one rule (0 = the first rule: "then", 1 =
#                             the "else" part when there is one). An action is {"kind":"device","datapointId","value","delaySeconds"?},
#                             {"kind":"sysvar","variableId","value","delaySeconds"?} or {"kind":"script","script","delaySeconds"?}.
#                             Every target and value is validated BEFORE anything is written (the datapoint must be writable, the
#                             value must fit its type and range: a percentage is sent as 0..100 and kept by ReGa as 0..1; HTTP 422
#                             names the offending field, "actions[2].value"). The change is made on a working copy of the program
#                             and copied back over the original in one step, as the classic editor does (RestoreProgram), so a
#                             failure leaves the program as it was; name, description, flags and the active state are kept. NOTE:
#                             putting the program back re-activates it as it was: for an ACTIVE program the CCU checks its
#                             conditions again and it can run at once. The answer is the program as GET gives it.
#   PUT    {"id","rule":<index>,"conditions":{"op"?,"groups":[{"from"?,"op"?,"conditions":[...]}]}}   EDITS the conditions of a rule
#                             that has some (not the "else" part). "op" between the groups and "op" of a group ("and" / "or") are
#                             one choice each, as in the classic editor. A condition is {"from"?,"kind":"device","datapointId",
#                             "test","value","value2"?,"trigger"?}, {"from"?,"kind":"sysvar","variableId",...} or, for a time
#                             control, {"from","kind":"time","trigger"?}. test: 1 = (a logic, list or button value), 5 =, 6 between,
#                             8 >, 9 >=, 10 <, 11 <=, 12 !=; trigger: 4 on change, 13 on update, 15 check only. "from" is the
#                             position in the program as GET gives it (group, and condition within the group): what is not named
#                             is DELETED, what is new is appended after the kept ones (ReGa cannot insert or move). A time control
#                             cannot be created, moved or turned into something else here, and deleting one (or its group) destroys
#                             its timer. Written on a working copy like the actions; the answer is the program as GET gives it.
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

set PROGRAM_ACTIONS_MAX 50
set PROGRAM_SCRIPT_MAX 32000
set PROGRAM_DELAY_MAX 359999

##
# What a datapoint of a device channel or a system variable is: its value type, range, list and unit, and whether it can be
# set. The id is the variable progTarget; kind is "device" or "sysvar". "" = not a valid target.
##
proc programs_targetInfo { kind id } {
  if { "device" eq $kind } then {
    set script {
      var dp = dom.GetObject(progTarget);
      if (dp)
      {
        if (dp.TypeName() == "HSSDP")
        {
          var ch = dom.GetObject(dp.Channel());
          if (ch)
          {
            if (!ch.Internal())
            {
              Write("TYPE {" # dp.ValueType() # "} SUB {" # dp.ValueSubType() # "} MIN {" # dp.ValueMin() # "} MAX {" # dp.ValueMax() # "} UNIT {" # dp.ValueUnit() # "} LIST {" # dp.ValueList() # "} OPS {" # dp.Operations() # "} CH {" # dp.Channel() # "} DONE {true}");
            }
          }
        }
      }
    }
  } else {
    set script {
      string i;
      foreach(i, dom.GetObject(ID_SYSTEM_VARIABLES).EnumIDs())
      {
        if (i == progTarget)
        {
          var sv = dom.GetObject(i);
          if (sv)
          {
            boolean takeSv = false;
            if (sv.Visible()) { if (false == sv.Internal()) { if (sv.ValueSubType() != istAlarm) { takeSv = true; } } }
            if (takeSv)
            {
              Write("TYPE {" # sv.ValueType() # "} SUB {" # sv.ValueSubType() # "} MIN {" # sv.ValueMin() # "} MAX {" # sv.ValueMax() # "} UNIT {" # sv.ValueUnit() # "} LIST {" # sv.ValueList() # "} OPS {2} CH {65535} DONE {true}");
            }
          }
        }
      }
    }
  }
  array set a [list progTarget $id]
  array set t {}
  catch { array set t [hmscript $script a] }
  if { ![info exists t(DONE)] } then { return "" }
  if { "device" eq $kind && 0 == ($t(OPS) & 2) } then { return "" }
  return [array get t]
}

##
# The value to hand to ReGa (as a string) and its kind (BOOL, FLOAT, INT, STRING) for a target, or "" when the value does not fit.
##
proc programs_actionValue { info value } {
  array set t $info
  set vt $t(TYPE)
  set sub $t(SUB)
  switch -- $vt {
    2 {
      if { "true" eq $value || ("false" eq $value && 28 != $sub) } then { return [list BOOL $value] }
    }
    16 {
      if { 29 == $sub } then {
        set n [llength [split $t(LIST) ";"]]
        if { [regexp {^[0-9]{1,4}$} $value] && [scan $value %d i] == 1 && $i < $n } then { return [list INT $i] }
      } elseif { [regexp {^-?[0-9]{1,9}$} $value] } then {
        scan $value %d i
        if { ![string is double -strict $t(MIN)] || ($i >= $t(MIN) && $i <= $t(MAX)) } then { return [list INT $i] }
      }
    }
    4 - 5 - 6 {
      if { [regexp {^-?[0-9]{1,15}(\.[0-9]{1,6})?$} $value] } then {
        set f [expr { double($value) }]
        if { "100%" eq $t(UNIT) } then { set f [expr { $f / 100.0 }] }
        if { ![string is double -strict $t(MIN)] || ![string is double -strict $t(MAX)] || ($f >= $t(MIN) - 1e-9 && $f <= $t(MAX) + 1e-9) } then { return [list FLOAT [format %.6f $f]] }
      }
    }
    20 {
      global SYSVAR_STRING_MAX
      if { [string length $value] <= 1000 && ![regexp {[\u0000-\u001f\u007f]} $value] } then { return [list STRING $value] }
    }
  }
  return ""
}

proc programs_delayParam { seconds } {
  return [format "%02d:%02d:%02d" [expr { $seconds / 3600 }] [expr { ($seconds % 3600) / 60 }] [expr { $seconds % 60 }]]
}

##
# Validates the actions of a request; answers HTTP 422 with the name of the field. Returns the list of plan entries:
# {kind K target ID valueKind VK value V delay D script S}
##
proc programs_planActions { actions } {
  global PROGRAM_ACTIONS_MAX PROGRAM_SCRIPT_MAX PROGRAM_DELAY_MAX
  if { [llength $actions] > $PROGRAM_ACTIONS_MAX } then { jsonrpc_error 403 "invalid argument (actions)" }
  set plan {}
  set n 0
  foreach a $actions {
    set f "actions\[$n\]"
    if { [catch { array set x $a }] } then { jsonrpc_error 403 "invalid argument ($f)" }
    foreach key [array names x] {
      if { $key ni {kind datapointId variableId value script delaySeconds} } then { jsonrpc_error 403 "invalid argument ($f.[regsub -all {[^A-Za-z0-9_.-]} [string range $key 0 39] _])" }
    }
    if { ![info exists x(kind)] || $x(kind) ni {device sysvar script} } then { jsonrpc_error 403 "invalid argument ($f.kind)" }
    set delay 0
    if { [info exists x(delaySeconds)] } then {
      if { ![regexp {^[0-9]{1,6}$} $x(delaySeconds)] || [scan $x(delaySeconds) %d delay] != 1 || $delay > $PROGRAM_DELAY_MAX } then { jsonrpc_error 403 "invalid argument ($f.delaySeconds)" }
    }
    set entry [list kind $x(kind) target "" valueKind STRING value "" delay $delay]
    if { "script" eq $x(kind) } then {
      if { ![info exists x(script)] || [string length $x(script)] > $PROGRAM_SCRIPT_MAX || [regexp {[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]} $x(script)] } then { jsonrpc_error 403 "invalid argument ($f.script)" }
      dict set entry value $x(script)
    } else {
      set idKey [expr { "device" eq $x(kind) ? "datapointId" : "variableId" }]
      if { ![info exists x($idKey)] || ![regexp {^[0-9]{1,10}$} $x($idKey)] } then { jsonrpc_error 403 "invalid argument ($f.$idKey)" }
      if { ![info exists x(value)] } then { jsonrpc_error 403 "invalid argument ($f.value)" }
      set info [programs_targetInfo $x(kind) $x($idKey)]
      if { "" == $info } then { jsonrpc_error 403 "invalid argument ($f.$idKey)" }
      set v [programs_actionValue $info $x(value)]
      if { "" == $v } then { jsonrpc_error 403 "invalid argument ($f.value)" }
      dict set entry target $x($idKey)
      dict set entry valueKind [lindex $v 0]
      dict set entry value [lindex $v 1]
    }
    lappend plan $entry
    array unset x
    incr n
  }
  return $plan
}

##
# Writes the plan: a working copy of the program gets the actions of the rule and is put back over the original in one step;
# any failure deletes the copy and leaves the original as it was. Returns 1 when the program holds the new actions.
##
proc programs_applyActions { id rule plan stopDelays } {
  set begin {
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
            integer k = 0;
            integer want = ruleIdx.ToInteger();
            object r = c.Rule();
            boolean found = false;
            while (r)
            {
              if (k == want)
              {
                found = true;
                object d = r.RuleDestination();
                integer guard = 0;
                while ((d.DestSingleCount() > 0) && (guard < 1000))
                {
                  object f = d.DestSingleDestination(0);
                  d.DestDelSingle(f.ID());
                  guard = guard + 1;
                }
                if (setStop == "true") { if (stopValue == "true") { d.BreakOnRestart(true); } else { d.BreakOnRestart(false); } }
                Write("COPY {" # c.ID() # "} CLEARED {" # (d.DestSingleCount() == 0) # "} DONE {true}");
              }
              r = r.RuleSubRule();
              k = k + 1;
            }
            if (!found)
            {
              if (c.ProgramCopyID() != ID_ERROR) { dom.DeleteObject(c.ID()); }
              Write("DONE {false}");
            }
          }
        }
      }
    }
  }
  set add {
    var c = dom.GetObject(copyId);
    if (c)
    {
      integer k = 0;
      integer want = ruleIdx.ToInteger();
      object r = c.Rule();
      while (r)
      {
        if (k == want)
        {
          object d = r.RuleDestination();
          object s = d.DestAddSingle();
          if (s)
          {
            boolean ok = true;
            if (actKind == "script")
            {
              s.DestinationParam(ivtString);
              s.DestinationValueType(ivtString);
              s.DestinationValue(actValue);
            }
            else
            {
              object tgt = dom.GetObject(actTarget);
              if (tgt)
              {
                if (actKind == "device")
                {
                  s.DestinationParam(ivtObjectId);
                  s.DestinationChannel(tgt.Channel());
                }
                else
                {
                  s.DestinationParam(ivtSystemId);
                }
                s.DestinationDP(tgt.ID());
                s.DestinationValueType(tgt.ValueType());
                if (valueKind == "BOOL") { if (actValue == "true") { s.DestinationValue(true); } else { s.DestinationValue(false); } }
                if (valueKind == "FLOAT") { real fv = actValue.ToFloat(); s.DestinationValue(fv); }
                if (valueKind == "INT") { integer iv = actValue.ToInteger(); s.DestinationValue(iv); }
                if (valueKind == "STRING") { s.DestinationValue(actValue); }
              }
              else { ok = false; }
            }
            if (ok)
            {
              if (actDelay != "")
              {
                s.DestinationValueParamType(ivtDelay);
                s.DestinationValueParam(actDelay);
              }
              Write("ADDED {true} COUNT {" # d.DestSingleCount() # "} DONE {true}");
            }
          }
        }
        r = r.RuleSubRule();
        k = k + 1;
      }
    }
  }
  set commit {
    var c = dom.GetObject(copyId);
    var p = dom.GetObject(progId);
    boolean ok = false;
    if (c)
    {
      if (p)
      {
        if ((c.ProgramCopyID() != ID_ERROR) && (c.ID() != p.ID()))
        {
          integer k = 0;
          integer want = ruleIdx.ToInteger();
          object r = c.Rule();
          while (r)
          {
            if (k == want) { if (r.RuleDestination().DestSingleCount() == expectCount.ToInteger()) { ok = true; } }
            r = r.RuleSubRule();
            k = k + 1;
          }
          if (ok)
          {
            boolean wasActive = p.Active();
            c.ProgramCopyTo(p.ID());
            dom.DeleteObject(c.ID());
            p.ProgramCopyID(ID_ERROR);
            p.ProgramUpdate();
            p.Active(wasActive);
          }
          else { dom.DeleteObject(c.ID()); }
        }
      }
    }
    Write("DONE {" # ok # "}");
  }
  set abort {
    var c = dom.GetObject(copyId);
    if (c)
    {
      if (c.IsTypeOf(OT_PROGRAM))
      {
        if ((c.ProgramCopyID() != ID_ERROR) && (c.ID() != progId.ToInteger())) { dom.DeleteObject(c.ID()); }
      }
    }
    Write("DONE {true}");
  }

  array set a [list progId $id ruleIdx $rule setStop [expr { "" == $stopDelays ? "false" : "true" }] stopValue $stopDelays]
  array set b {}
  catch { array set b [hmscript $begin a] }
  if { ![info exists b(COPY)] || ![string is true -strict $b(CLEARED)] } then { return 0 }
  set copy $b(COPY)
  foreach entry $plan {
    array set e $entry
    set delay [expr { $e(delay) > 0 ? [programs_delayParam $e(delay)] : "" }]
    array set ad [list copyId $copy ruleIdx $rule actKind $e(kind) actTarget $e(target) valueKind $e(valueKind) actValue $e(value) actDelay $delay]
    array set r {}
    catch { array set r [hmscript $add ad] }
    array unset ad
    array unset e
    if { ![info exists r(ADDED)] } then {
      array set ab [list copyId $copy progId $id]
      catch { hmscript $abort ab }
      return 0
    }
    array unset r
  }
  array set cm [list copyId $copy progId $id ruleIdx $rule expectCount [llength $plan]]
  array set done {}
  catch { array set done [hmscript $commit cm] }
  if { ![info exists done(DONE)] || ![string is true -strict $done(DONE)] } then {
    array set ab [list copyId $copy progId $id]
    catch { hmscript $abort ab }
    return 0
  }
  return 1
}

set PROGRAM_GROUPS_MAX 20
set PROGRAM_CONDS_MAX 30
set PROGRAM_TESTS {1 5 6 8 9 10 11 12}
set PROGRAM_TRIGGERS {1 4 13 15}

##
# The structure of the conditions of a rule as it is now: the number of groups and, per group, the kind of each single condition
# (device, sysvar, time, other). "" = ReGa did not answer; "norule" = there is no such rule; "nocond" = the rule has no conditions
# (the else part).
##
proc programs_condStructure { id rule } {
  set script {
    string i;
    foreach(i, dom.GetObject(ID_PROGRAMS).EnumIDs())
    {
      if (i == progId)
      {
        var p = dom.GetObject(i);
        if (p)
        {
          integer k = 0;
          integer want = ruleIdx.ToInteger();
          object r = p.Rule();
          while (r)
          {
            if (k == want)
            {
              WriteLine("RULE HASCOND {" # r.ElseIfFlag() # "}");
              integer nc = r.RuleConditions().Count();
              if (nc > 0)
              {
                string ci;
                foreach (ci, system.GenerateEnum(0, nc - 1))
                {
                  object c = r.RuleCondition(ci);
                  integer ns = c.CndSingleCount();
                  string line = "";
                  if (ns > 0)
                  {
                    string si;
                    foreach (si, system.GenerateEnum(0, ns - 1)) { line = line # " " # c.CndSingleCondition(si).LeftValType(); }
                  }
                  WriteLine("GROUP G {" # ci # "} KINDS {" # line # "}");
                }
              }
            }
            r = r.RuleSubRule();
            k = k + 1;
          }
          WriteLine("END DONE {true}");
        }
      }
    }
  }
  array set a [list progId $id ruleIdx $rule]
  set out ""
  catch { set out [hmscript $script a] }
  set hasRule 0
  set hasCond 0
  set groups {}
  set done 0
  foreach line [split $out "\n"] {
    set line [string trim $line]
    if { "" == $line || [catch { llength $line }] } then { continue }
    array unset f
    if { [catch { array set f [lrange $line 1 end] }] } then { continue }
    switch -- [lindex $line 0] {
      RULE { set hasRule 1; set hasCond [string is true -strict $f(HASCOND)] }
      GROUP {
        set kinds {}
        foreach lt $f(KINDS) { lappend kinds [expr { 18 == $lt ? "device" : 19 == $lt ? "sysvar" : 24 == $lt ? "time" : "other" }] }
        lappend groups $kinds
      }
      END { set done 1 }
    }
  }
  if { !$done } then { return "" }
  if { !$hasRule } then { return norule }
  if { !$hasCond } then { return nocond }
  return [list $groups]
}

##
# What a datapoint (readable or reporting) or a system variable is, for a condition. Alarms count as logic values; a text
# variable and the like are not supported ("").
##
proc programs_condTargetInfo { kind id } {
  if { "device" eq $kind } then {
    set script {
      var dp = dom.GetObject(progTarget);
      if (dp)
      {
        if (dp.TypeName() == "HSSDP")
        {
          var ch = dom.GetObject(dp.Channel());
          if (ch)
          {
            if (false == ch.Internal())
            {
              if ((OPERATION_READ | OPERATION_EVENT) & dp.Operations())
              {
                Write("TYPE {" # dp.ValueType() # "} SUB {" # dp.ValueSubType() # "} MIN {" # dp.ValueMin() # "} MAX {" # dp.ValueMax() # "} UNIT {" # dp.ValueUnit() # "} LIST {" # dp.ValueList() # "} CH {" # dp.Channel() # "} DONE {true}");
              }
            }
          }
        }
      }
    }
  } else {
    set script {
      string i;
      foreach(i, dom.GetObject(ID_SYSTEM_VARIABLES).EnumIDs())
      {
        if (i == progTarget)
        {
          var sv = dom.GetObject(i);
          if (sv)
          {
            boolean takeSv = false;
            if (sv.Visible()) { if (false == sv.Internal()) { takeSv = true; } }
            if (takeSv)
            {
              Write("TYPE {" # sv.ValueType() # "} SUB {" # sv.ValueSubType() # "} MIN {" # sv.ValueMin() # "} MAX {" # sv.ValueMax() # "} UNIT {" # sv.ValueUnit() # "} LIST {" # sv.ValueList() # "} CH {65535} DONE {true}");
            }
          }
        }
      }
    }
  }
  array set a [list progTarget $id]
  array set t {}
  catch { array set t [hmscript $script a] }
  if { ![info exists t(DONE)] } then { return "" }
  return [array get t]
}

##
# One condition of the request, checked against ReGa and turned into a plan entry:
#   {kind K target ID test T trigger G valueKind VK right R right2 R2 from F}
# or {kind time from F trigger G}. $f names the field in the answer of HTTP 422.
##
proc programs_planCondition { c f structure gi } {
  global PROGRAM_TESTS PROGRAM_TRIGGERS
  if { [catch { array set x $c }] } then { jsonrpc_error 403 "invalid argument ($f)" }
  foreach key [array names x] {
    if { $key ni {from kind datapointId variableId test value value2 trigger} } then { jsonrpc_error 403 "invalid argument ($f.[regsub -all {[^A-Za-z0-9_.-]} [string range $key 0 39] _])" }
  }
  if { ![info exists x(kind)] || $x(kind) ni {device sysvar time} } then { jsonrpc_error 403 "invalid argument ($f.kind)" }
  set from -1
  if { [info exists x(from)] } then {
    if { ![regexp {^[0-9]{1,3}$} $x(from)] || $gi < 0 || $x(from) >= [llength [lindex $structure $gi]] } then { jsonrpc_error 403 "invalid argument ($f.from)" }
    scan $x(from) %d from
  }
  set trigger 4
  if { [info exists x(trigger)] } then {
    if { ![regexp {^[0-9]{1,2}$} $x(trigger)] || $x(trigger) ni $PROGRAM_TRIGGERS } then { jsonrpc_error 403 "invalid argument ($f.trigger)" }
    set trigger $x(trigger)
  }
  if { "time" eq $x(kind) } then {
    # a time control stays where it is: it is only kept (its timer cannot be made here) and may change how it triggers
    if { $from < 0 || "time" ne [lindex [lindex $structure $gi] $from] } then { jsonrpc_error 403 "invalid argument ($f.from)" }
    if { ![info exists x(trigger)] } then { set trigger 13 }
    if { $trigger ni {13 15} } then { jsonrpc_error 403 "invalid argument ($f.trigger)" }
    return [list kind time from $from trigger $trigger]
  }
  if { $from >= 0 && "time" eq [lindex [lindex $structure $gi] $from] } then { jsonrpc_error 403 "invalid argument ($f.from)" }
  set idKey [expr { "device" eq $x(kind) ? "datapointId" : "variableId" }]
  if { ![info exists x($idKey)] || ![regexp {^[0-9]{1,10}$} $x($idKey)] } then { jsonrpc_error 403 "invalid argument ($f.$idKey)" }
  set info [programs_condTargetInfo $x(kind) $x($idKey)]
  if { "" == $info } then { jsonrpc_error 403 "invalid argument ($f.$idKey)" }
  array set t $info
  if { ![info exists x(test)] || ![regexp {^[0-9]{1,2}$} $x(test)] || $x(test) ni $PROGRAM_TESTS } then { jsonrpc_error 403 "invalid argument ($f.test)" }
  if { ![info exists x(value)] } then { jsonrpc_error 403 "invalid argument ($f.value)" }
  set kindOfValue ""
  set right ""
  set right2 ""
  switch -- $t(TYPE) {
    2 {
      # a logic value, an alarm or a button: only "is"
      if { 1 != $x(test) } then { jsonrpc_error 403 "invalid argument ($f.test)" }
      if { $x(value) ne "true" && ($x(value) ne "false" || 28 == $t(SUB)) } then { jsonrpc_error 403 "invalid argument ($f.value)" }
      set kindOfValue BOOL
      set right $x(value)
      if { 28 == $t(SUB) } then { set trigger 1 } elseif { 1 == $trigger } then { set trigger 4 }
    }
    16 {
      if { 29 == $t(SUB) } then {
        set n [llength [split $t(LIST) ";"]]
        if { 1 != $x(test) } then { jsonrpc_error 403 "invalid argument ($f.test)" }
        if { ![regexp {^[0-9]{1,4}$} $x(value)] || [scan $x(value) %d right] != 1 || $right >= $n } then { jsonrpc_error 403 "invalid argument ($f.value)" }
        set kindOfValue INT
        if { 1 == $trigger } then { set trigger 4 }
      }
    }
  }
  if { "" == $kindOfValue } then {
    # a number (integer, float or scaling): the comparisons that take one value, or "between"
    if { $t(TYPE) ni {4 5 6 16} || 1 == $x(test) } then { jsonrpc_error 403 "invalid argument ($f.[expr { $t(TYPE) in {4 5 6 16} ? "test" : "datapointId" }])" }
    set integer [expr { 16 == $t(TYPE) }]
    set re [expr { $integer ? {^-?[0-9]{1,9}$} : {^-?[0-9]{1,15}(\.[0-9]{1,6})?$} }]
    if { ![regexp $re $x(value)] } then { jsonrpc_error 403 "invalid argument ($f.value)" }
    set right $x(value)
    if { 6 == $x(test) } then {
      if { ![info exists x(value2)] || ![regexp $re $x(value2)] || double($x(value)) > double($x(value2)) } then { jsonrpc_error 403 "invalid argument ($f.value2)" }
      set right2 $x(value2)
    }
    if { "100%" eq $t(UNIT) } then {
      set right [format %.6f [expr { double($right) / 100.0 }]]
      if { "" ne $right2 } then { set right2 [format %.6f [expr { double($right2) / 100.0 }]] }
    }
    set kindOfValue [expr { $integer ? "INT" : "FLOAT" }]
    if { 1 == $trigger } then { set trigger 4 }
  }
  return [list kind $x(kind) target $x($idKey) test $x(test) trigger $trigger valueKind $kindOfValue right $right right2 $right2 from $from]
}

##
# The whole conditions of a request as a plan, checked against the structure of the rule as it is now. Returns
# {groupOp OP groups {{from G op OP singles {entry ...}} ...}}; answers HTTP 422 naming the field otherwise.
##
proc programs_planConditions { cond structure } {
  global PROGRAM_GROUPS_MAX PROGRAM_CONDS_MAX
  if { [catch { array set c $cond }] } then { jsonrpc_error 403 "invalid argument (conditions)" }
  foreach key [array names c] { if { $key ni {op groups} } then { jsonrpc_error 403 "invalid argument (conditions.[regsub -all {[^A-Za-z0-9_.-]} [string range $key 0 39] _])" } }
  if { ![info exists c(groups)] || ![regexp {"groups"\s*:\s*\[} [v2_body]] || [llength $c(groups)] > $PROGRAM_GROUPS_MAX } then { jsonrpc_error 403 "invalid argument (conditions.groups)" }
  set groupOp and
  if { [info exists c(op)] } then {
    if { $c(op) ni {and or} } then { jsonrpc_error 403 "invalid argument (conditions.op)" }
    set groupOp $c(op)
  }
  set plan {}
  set seenGroups {}
  set lastKept -1
  set sawNew 0
  set gn 0
  foreach g $c(groups) {
    set gf "conditions.groups\[$gn\]"
    if { [catch { array set gx $g }] } then { jsonrpc_error 403 "invalid argument ($gf)" }
    foreach key [array names gx] { if { $key ni {from op conditions} } then { jsonrpc_error 403 "invalid argument ($gf.[regsub -all {[^A-Za-z0-9_.-]} [string range $key 0 39] _])" } }
    set from -1
    if { [info exists gx(from)] } then {
      if { ![regexp {^[0-9]{1,3}$} $gx(from)] || $gx(from) >= [llength $structure] } then { jsonrpc_error 403 "invalid argument ($gf.from)" }
      scan $gx(from) %d from
      # the kept groups stay in their order, and no group is kept twice
      if { $from <= $lastKept || $sawNew } then { jsonrpc_error 403 "invalid argument ($gf.from)" }
      set lastKept $from
    } else { set sawNew 1 }
    set innerOp and
    if { [info exists gx(op)] } then {
      if { $gx(op) ni {and or} } then { jsonrpc_error 403 "invalid argument ($gf.op)" }
      set innerOp $gx(op)
    }
    if { ![info exists gx(conditions)] || 0 == [llength $gx(conditions)] || [llength $gx(conditions)] > $PROGRAM_CONDS_MAX } then { jsonrpc_error 403 "invalid argument ($gf.conditions)" }
    set singles {}
    set lastSingle -1
    set sawNewSingle 0
    set cn 0
    foreach cc $gx(conditions) {
      set cf "$gf.conditions\[$cn\]"
      set entry [programs_planCondition $cc $cf $structure $from]
      set sf [dict get $entry from]
      if { $sf >= 0 } then {
        if { $sf <= $lastSingle || $sawNewSingle } then { jsonrpc_error 403 "invalid argument ($cf.from)" }
        set lastSingle $sf
      } else {
        if { "time" eq [dict get $entry kind] } then { jsonrpc_error 403 "invalid argument ($cf.kind)" }
        set sawNewSingle 1
      }
      lappend singles $entry
      incr cn
    }
    # a group that is new cannot hold a kept condition (ReGa cannot move one)
    if { $from < 0 } then { foreach e $singles { if { [dict get $e from] >= 0 } then { jsonrpc_error 403 "invalid argument ($gf.conditions)" } } }
    lappend plan [list from $from op $innerOp singles $singles]
    array unset gx
    incr gn
  }
  return [list groupOp $groupOp groups $plan]
}

##
# One operation on the working copy (a ReGa script with its variables): the answer of the script, or "" when ReGa did not
# report DONE true.
##
proc programs_condOp { script copy rule args } {
  # ReGa rejects the WHOLE script when it names a variable that is not defined, even in a branch that does not run: every
  # variable of the script gets a value, the arguments override them
  set defaults [list opName "" grpIdx 0 sglIdx "" opCode 1 trigger 4 kindName "" targetId 0 testCode 1 valueKind "" rv1 "" rv2 ""]
  array set pa [concat [list copyId $copy ruleIdx $rule] $defaults $args]
  array set pr {}
  catch { array set pr [hmscript $script pa] }
  if { ![info exists pr(DONE)] || ![string is true -strict $pr(DONE)] } then {
    catch { api_syslog daemon.warning "cid=[api_cid] method=PUT /api/v2/programs uid=[v2_sessionUid] the operation $pa(opName) on the working copy failed" }
    return ""
  }
  return [array get pr]
}

##
# Writes a conditions plan: on a working copy of the program, in place (a time control keeps its timer), then the copy is put back
# over the original in one step. Any failure deletes the copy and leaves the original as it was. Returns 1 on success.
##
proc programs_applyConditions { id rule structure plan } {
  set begin {
    string i;
    foreach(i, dom.GetObject(ID_PROGRAMS).EnumIDs())
    {
      if (i == progId)
      {
        var p = dom.GetObject(i);
        if (p)
        {
          var c = p.ProgramCopyTo();
          if (c) { Write("COPY {" # c.ID() # "} DONE {true}"); }
        }
      }
    }
  }
  set op {
    var c = dom.GetObject(copyId);
    boolean ok = false;
    if (c)
    {
      integer k = 0;
      integer want = ruleIdx.ToInteger();
      object r = c.Rule();
      while (r)
      {
        if (k == want)
        {
          if (opName == "addGroup")
          {
            object ng = r.RuleAddCondition();
            if (ng) { ok = true; Write("INDEX {" # (r.RuleConditions().Count() - 1) # "} "); }
          }
          if (opName == "delGroup")
          {
            object dg = r.RuleCondition(grpIdx.ToInteger());
            if (dg) { ok = r.RuleDelCondition(dg.ID()); }
          }
          if (opName == "delSingle")
          {
            object g1 = r.RuleCondition(grpIdx.ToInteger());
            if (g1) { object d1 = g1.CndSingleCondition(sglIdx.ToInteger()); if (d1) { ok = g1.CndDelSingle(d1.ID()); } }
          }
          if (opName == "groupOp")
          {
            object g2 = r.RuleCondition(grpIdx.ToInteger());
            if (g2) { g2.CndOperatorType(opCode.ToInteger()); ok = true; }
          }
          if (opName == "innerOp")
          {
            object g3 = r.RuleCondition(grpIdx.ToInteger());
            if (g3)
            {
              integer n3 = g3.CndSingleCount();
              integer j3 = 0;
              while (j3 < n3) { g3.CndSingleCondition(j3).OperatorType(opCode.ToInteger()); j3 = j3 + 1; }
              ok = true;
            }
          }
          if (opName == "timeTrigger")
          {
            object g4 = r.RuleCondition(grpIdx.ToInteger());
            if (g4) { object s4 = g4.CndSingleCondition(sglIdx.ToInteger()); if (s4) { s4.ConditionType2(trigger.ToInteger()); ok = true; } }
          }
          if (opName == "setSingle")
          {
            object g5 = r.RuleCondition(grpIdx.ToInteger());
            if (g5)
            {
              object s5 = null;
              if (sglIdx == "") { s5 = g5.CndAddSingle(); } else { s5 = g5.CndSingleCondition(sglIdx.ToInteger()); }
              object tgt = dom.GetObject(targetId.ToInteger());
              if (s5)
              {
                if (tgt)
                {
                  if (kindName == "device")
                  {
                    s5.LeftValType(ivtObjectId);
                    s5.LeftVal(tgt.ID());
                    s5.ConditionChannel(tgt.Channel());
                  }
                  else
                  {
                    s5.LeftValType(ivtSystemId);
                    s5.LeftVal(tgt.ID());
                    s5.ConditionChannel(ID_ERROR);
                  }
                  s5.ConditionType(testCode.ToInteger());
                  s5.ConditionType2(trigger.ToInteger());
                  if (valueKind == "BOOL") { if (rv1 == "true") { s5.RightVal1(true); } else { s5.RightVal1(false); } }
                  if (valueKind == "INT") { integer iv = rv1.ToInteger(); s5.RightVal1(iv); }
                  if (valueKind == "FLOAT") { real fv = rv1.ToFloat(); s5.RightVal1(fv); }
                  if (rv2 != "") { real fv2 = rv2.ToFloat(); s5.RightVal2(fv2); }
                  ok = true;
                }
              }
            }
          }
          if (opName == "counts")
          {
            integer n6 = r.RuleConditions().Count();
            string line6 = "";
            if (n6 > 0) { string ci6; foreach (ci6, system.GenerateEnum(0, n6 - 1)) { line6 = line6 # " " # r.RuleCondition(ci6).CndSingleCount(); } }
            Write("COUNTS {" # line6 # "} ");
            ok = true;
          }
        }
        r = r.RuleSubRule();
        k = k + 1;
      }
    }
    Write("DONE {" # ok # "}");
  }
  set commit {
    var c = dom.GetObject(copyId);
    var p = dom.GetObject(progId);
    boolean ok = false;
    if (c)
    {
      if (p)
      {
        if ((c.ProgramCopyID() != ID_ERROR) && (c.ID() != p.ID()))
        {
          boolean wasActive = p.Active();
          c.ProgramCopyTo(p.ID());
          dom.DeleteObject(c.ID());
          p.ProgramCopyID(ID_ERROR);
          p.ProgramUpdate();
          p.Active(wasActive);
          ok = true;
        }
      }
    }
    Write("DONE {" # ok # "}");
  }
  set abort {
    var c = dom.GetObject(copyId);
    if (c)
    {
      if (c.IsTypeOf(OT_PROGRAM))
      {
        if ((c.ProgramCopyID() != ID_ERROR) && (c.ID() != progId.ToInteger())) { dom.DeleteObject(c.ID()); }
      }
    }
    Write("DONE {true}");
  }

  array set a [list progId $id]
  array set b {}
  catch { array set b [hmscript $begin a] }
  if { ![info exists b(COPY)] } then { return 0 }
  set copy $b(COPY)
  set fail 0
  set groups [dict get $plan groups]
  set keptOld {}
  foreach g $groups { if { [dict get $g from] >= 0 } then { lappend keptOld [dict get $g from] } }

  # 1. the groups that are not kept go (from the end, so the positions below stay right)
  for { set og [expr { [llength $structure] - 1 }] } { $og >= 0 && !$fail } { incr og -1 } {
    if { $og ni $keptOld } then { if { "" == [programs_condOp $op $copy $rule opName delGroup grpIdx $og] } then { set fail 1 } }
  }
  # 2. in the kept groups the conditions that are not kept go; 3. the kept ones are updated in place
  set gi 0
  foreach g $groups {
    if { $fail } then { break }
    if { [dict get $g from] >= 0 } then {
      set og [dict get $g from]
      set keptSingles {}
      foreach e [dict get $g singles] { if { [dict get $e from] >= 0 } then { lappend keptSingles [dict get $e from] } }
      for { set si [expr { [llength [lindex $structure $og]] - 1 }] } { $si >= 0 && !$fail } { incr si -1 } {
        if { $si ni $keptSingles } then { if { "" == [programs_condOp $op $copy $rule opName delSingle grpIdx $gi sglIdx $si] } then { set fail 1 } }
      }
      set rank 0
      foreach e [dict get $g singles] {
        if { $fail || [dict get $e from] < 0 } then { continue }
        if { "time" eq [dict get $e kind] } then {
          if { "" == [programs_condOp $op $copy $rule opName timeTrigger grpIdx $gi sglIdx $rank trigger [dict get $e trigger]] } then { set fail 1 }
        } else {
          if { "" == [programs_condOp $op $copy $rule opName setSingle grpIdx $gi sglIdx $rank kindName [dict get $e kind] targetId [dict get $e target] testCode [dict get $e test] trigger [dict get $e trigger] valueKind [dict get $e valueKind] rv1 [dict get $e right] rv2 [dict get $e right2]] } then { set fail 1 }
        }
        incr rank
      }
      incr gi
    }
  }
  # 4. what is new is appended: new conditions to the kept groups, then the new groups
  set gi 0
  foreach g $groups {
    if { $fail } then { break }
    if { [dict get $g from] < 0 } then {
      set r [programs_condOp $op $copy $rule opName addGroup]
      if { "" == $r } then { set fail 1; break }
      array set ri $r
      set gi $ri(INDEX)
      array unset ri
    }
    foreach e [dict get $g singles] {
      if { $fail } then { break }
      if { [dict get $e from] >= 0 } then { continue }
      if { "" == [programs_condOp $op $copy $rule opName setSingle grpIdx $gi sglIdx "" kindName [dict get $e kind] targetId [dict get $e target] testCode [dict get $e test] trigger [dict get $e trigger] valueKind [dict get $e valueKind] rv1 [dict get $e right] rv2 [dict get $e right2]] } then { set fail 1 }
    }
    if { [dict get $g from] >= 0 } then { incr gi }
  }
  # 5. the operators: one between the groups, one inside each group (as the classic editor keeps them)
  set n 0
  foreach g $groups {
    if { $fail } then { break }
    if { "" == [programs_condOp $op $copy $rule opName groupOp grpIdx $n opCode [expr { "and" eq [dict get $plan groupOp] ? 1 : 2 }]] } then { set fail 1; break }
    if { "" == [programs_condOp $op $copy $rule opName innerOp grpIdx $n opCode [expr { "and" eq [dict get $g op] ? 1 : 2 }]] } then { set fail 1; break }
    incr n
  }
  # 6. the copy must have exactly the structure that was asked for
  if { !$fail } then {
    set want {}
    foreach g $groups { lappend want [llength [dict get $g singles]] }
    set r [programs_condOp $op $copy $rule opName counts]
    array set cn {}
    if { "" != $r } then { array set cn $r }
    if { ![info exists cn(COUNTS)] || [string trim $cn(COUNTS)] ne [join $want " "] } then { set fail 1 }
  }
  if { !$fail } then {
    array set cm [list copyId $copy progId $id]
    array set done {}
    catch { array set done [hmscript $commit cm] }
    if { [info exists done(DONE)] && [string is true -strict $done(DONE)] } then { return 1 }
  }
  array set ab [list copyId $copy progId $id]
  catch { hmscript $abort ab }
  return 0
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

proc programs_putConditions { uid bodyList } {
  array set body $bodyList
  foreach k {name description isVisible isOperable actions stopDelays} { if { [info exists body($k)] } then { jsonrpc_error 403 "invalid argument ($k)" } }
  if { ![info exists body(rule)] || ![regexp {^[0-9]{1,2}$} $body(rule)] } then { jsonrpc_error 403 "invalid argument (rule)" }
  set id $body(id)
  programs_requireManageable $id
  scan $body(rule) %d rule
  set structure [programs_condStructure $id $rule]
  if { "" == $structure } then { programs_failed PUT "read the conditions of program $id" }
  if { "norule" eq $structure } then { jsonrpc_error 403 "invalid argument (rule)" }
  if { "nocond" eq $structure } then { jsonrpc_error 403 "invalid argument (rule)" }
  set structure [lindex $structure 0]
  set plan [programs_planConditions $body(conditions) $structure]
  if { ![programs_applyConditions $id $rule $structure $plan] } then { programs_failed PUT "change the conditions of program $id" }
  set n 0
  foreach g [dict get $plan groups] { incr n [llength [dict get $g singles]] }
  api_syslog daemon.notice "cid=[api_cid] method=PUT /api/v2/programs uid=$uid action=change the conditions of program $id rule $rule: [llength [dict get $plan groups]] group(s), $n condition(s)"
  set d [programs_describe $id]
  set rules [programs_logic $id]
  if { "" == $d || "" == $rules } then { programs_failed PUT "read program $id after the change" }
  set base [programs_json $id $d]
  v2_respondJson "[string range $base 0 end-1],\"rules\":$rules\}"
}

proc programs_putActions { uid bodyList } {
  array set body $bodyList
  foreach k {name description isVisible isOperable} { if { [info exists body($k)] } then { jsonrpc_error 403 "invalid argument ($k)" } }
  if { ![info exists body(rule)] || ![regexp {^[0-9]{1,2}$} $body(rule)] } then { jsonrpc_error 403 "invalid argument (rule)" }
  if { ![info exists body(actions)] || ![regexp {"actions"\s*:\s*\[} [v2_body]] } then { jsonrpc_error 403 "invalid argument (actions)" }
  set stop ""
  if { [info exists body(stopDelays)] } then {
    if { $body(stopDelays) ne "true" && $body(stopDelays) ne "false" } then { jsonrpc_error 403 "invalid argument (stopDelays)" }
    set stop $body(stopDelays)
  }
  set plan [programs_planActions $body(actions)]
  set id $body(id)
  programs_requireManageable $id
  if { ![programs_applyActions $id $body(rule) $plan $stop] } then { programs_failed PUT "change the actions of program $id" }
  api_syslog daemon.notice "cid=[api_cid] method=PUT /api/v2/programs uid=$uid action=change the actions of program $id rule $body(rule): [llength $plan] action(s)"
  set d [programs_describe $id]
  set rules [programs_logic $id]
  if { "" == $d || "" == $rules } then { programs_failed PUT "read program $id after the change" }
  set base [programs_json $id $d]
  v2_respondJson "[string range $base 0 end-1],\"rules\":$rules\}"
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
    array set body [programs_parseBody {id name description isVisible isOperable rule actions stopDelays conditions}]
    if { ![info exists body(id)] || ![regexp {^[0-9]{1,10}$} $body(id)] } then { jsonrpc_error 403 "invalid argument (id)" }
    if { [info exists body(conditions)] } then {
      programs_putConditions $uid [array get body]
      return
    }
    if { [info exists body(actions)] || [info exists body(rule)] || [info exists body(stopDelays)] } then {
      programs_putActions $uid [array get body]
      return
    }
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
                  string dchn = ""; string ddpn = ""; string dvt = ""; string ddu = ""; string dv = "" # sd.DestinationValue(); string dvp = "" # sd.DestinationValueParam();
                  if (dch) { dchn = dch.Name(); }
                  if (ddp) { ddpn = ddp.Name(); dvt = ddp.ValueType() # "/" # ddp.ValueSubType(); ddu = ddp.ValueUnit(); }
                  dchn = dchn.Replace("\\", "\\\\"); dchn = dchn.Replace("{", "\\o"); dchn = dchn.Replace("}", "\\c"); dchn = dchn.Replace("\r", ""); dchn = dchn.Replace("\n", "\\n");
                  ddpn = ddpn.Replace("\\", "\\\\"); ddpn = ddpn.Replace("{", "\\o"); ddpn = ddpn.Replace("}", "\\c"); ddpn = ddpn.Replace("\r", ""); ddpn = ddpn.Replace("\n", "\\n");
                  dv = dv.Replace("\\", "\\\\"); dv = dv.Replace("{", "\\o"); dv = dv.Replace("}", "\\c"); dv = dv.Replace("\r", ""); dv = dv.Replace("\n", "\\n");
                  ddu = ddu.Replace("\\", "\\\\"); ddu = ddu.Replace("{", "\\o"); ddu = ddu.Replace("}", "\\c"); ddu = ddu.Replace("\r", ""); ddu = ddu.Replace("\n", "\\n");
                  dvp = dvp.Replace("\\", "\\\\"); dvp = dvp.Replace("{", "\\o"); dvp = dvp.Replace("}", "\\c"); dvp = dvp.Replace("\r", ""); dvp = dvp.Replace("\n", "\\n");
                  WriteLine("DEST P {" # sd.DestinationParam() # "} VT {" # sd.DestinationValueType() # "} VPT {" # sd.DestinationValueParamType() # "} V {" # dv # "} VP {" # dvp # "} CH {" # sd.DestinationChannel() # "} DP {" # sd.DestinationDP() # "} CHN {" # dchn # "} DPN {" # ddpn # "} DPT {" # dvt # "} DPU {" # ddu # "}");
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
        # a line from an older script has no unit
        if { ![info exists f(DPU)] } then { set f(DPU) "" }
        foreach k {V VP CHN DPN DPT DPU} { set f($k) [programs_unescape $f($k)] }
        set acts [dict get $rule actions]
        lappend acts [list param [programs_num $f(P)] valueType [programs_num $f(VT)] delayType [programs_num $f(VPT)] value $f(V) delay $f(VP) channelId $f(CH) datapointId $f(DP) channelName $f(CHN) datapointName $f(DPN) datapointType $f(DPT) datapointUnit $f(DPU)]
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
  foreach k {value delay channelId datapointId channelName datapointName datapointType datapointUnit} { append j ",\"$k\":[json_toString [dict get $a $k]]" }
  return "$j\}"
}

##
# The things an action can set: every writable datapoint of a device channel and every system variable that users may set. One
# bulk script (never one per device); the answer is {"datapoints":[...],"variables":[...]}.
##
proc programs_targets { mode } {
  set dpScript {
    string dId;
    string cId;
    string pId;
    foreach(dId, root.Devices().EnumIDs())
    {
      var dev = dom.GetObject(dId);
      if (dev)
      {
        foreach(cId, dev.Channels())
        {
          var channel = dom.GetObject(cId);
          boolean takeCh = false;
          if (channel) { if (false == channel.Internal()) { takeCh = true; } }
          if (takeCh)
          {
            foreach(pId, channel.DPs())
            {
              var dp = dom.GetObject(pId);
              boolean takeDp = false;
              if (dp) { if (dp.TypeName() == "HSSDP") { if (!dp.Internal()) { if (%DPOPS% & dp.Operations()) { takeDp = true; } } } }
              if (takeDp)
              {
                WriteLine("{");
                WriteLine("ID {" # dp.ID() # "}");
                WriteLine("NAME {" # dp.HSSID() # "}");
                WriteLine("CHANNEL {" # channel.Name() # "}");
                WriteLine("DEVICE {" # dev.Name() # "}");
                WriteLine("TYPE {" # dp.ValueType() # "}");
                WriteLine("SUB {" # dp.ValueSubType() # "}");
                WriteLine("MIN {" # dp.ValueMin() # "}");
                WriteLine("MAX {" # dp.ValueMax() # "}");
                WriteLine("UNIT {" # dp.ValueUnit() # "}");
                WriteLine("LIST {" # dp.ValueList() # "}");
                WriteLine("}");
              }
            }
          }
        }
      }
    }
  }
  set svScript {
    string i;
    foreach(i, dom.GetObject(ID_SYSTEM_VARIABLES).EnumIDs())
    {
      var sv = dom.GetObject(i);
      if (sv)
      {
        boolean takeSv = false;
        if (sv.Visible()) { if (false == sv.Internal()) { %SVFILTER% } }
        if (takeSv)
        {
          WriteLine("{");
          WriteLine("ID {" # sv.ID() # "}");
          WriteLine("NAME {" # sv.Name() # "}");
          WriteLine("TYPE {" # sv.ValueType() # "}");
          WriteLine("SUB {" # sv.ValueSubType() # "}");
          WriteLine("MIN {" # sv.ValueMin() # "}");
          WriteLine("MAX {" # sv.ValueMax() # "}");
          WriteLine("UNIT {" # sv.ValueUnit() # "}");
          WriteLine("LIST {" # sv.ValueList() # "}");
          WriteLine("NAME0 {" # sv.ValueName0() # "}");
          WriteLine("NAME1 {" # sv.ValueName1() # "}");
          WriteLine("}");
        }
      }
    }
  }
  # actions set things (writable datapoints, no alarm variables); conditions look at them (readable or reporting datapoints, alarms
  # are logic values, a text variable is not supported)
  if { "conditions" eq $mode } then {
    set dpScript [string map [list %DPOPS% "(OPERATION_READ | OPERATION_EVENT)"] $dpScript]
    set svScript [string map [list %SVFILTER% "if (sv.ValueType() != ivtString) { takeSv = true; }"] $svScript]
  } else {
    set dpScript [string map [list %DPOPS% OPERATION_WRITE] $dpScript]
    set svScript [string map [list %SVFILTER% "if (sv.ValueSubType() != istAlarm) { takeSv = true; }"] $svScript]
  }
  set dps {}
  foreach rec [v2_records [hmscript $dpScript]] {
    if { [catch { array set p $rec }] || ![info exists p(ID)] } then { array unset p; continue }
    foreach k {NAME CHANNEL DEVICE TYPE SUB MIN MAX UNIT LIST} { if { ![info exists p($k)] } then { set p($k) "" } }
    lappend dps "\{\"id\":[json_toString $p(ID)],\"param\":[json_toString $p(NAME)],\"channel\":[json_toString $p(CHANNEL)],\"device\":[json_toString $p(DEVICE)],\"valueType\":[programs_num $p(TYPE)],\"subType\":[programs_num $p(SUB)],\"min\":[json_toString $p(MIN)],\"max\":[json_toString $p(MAX)],\"unit\":[json_toString $p(UNIT)],\"valueList\":[json_toString $p(LIST)]\}"
    array unset p
  }
  set svs {}
  foreach rec [v2_records [hmscript $svScript]] {
    if { [catch { array set p $rec }] || ![info exists p(ID)] } then { array unset p; continue }
    foreach k {NAME TYPE SUB MIN MAX UNIT LIST NAME0 NAME1} { if { ![info exists p($k)] } then { set p($k) "" } }
    lappend svs "\{\"id\":[json_toString $p(ID)],\"name\":[json_toString $p(NAME)],\"valueType\":[programs_num $p(TYPE)],\"subType\":[programs_num $p(SUB)],\"min\":[json_toString $p(MIN)],\"max\":[json_toString $p(MAX)],\"unit\":[json_toString $p(UNIT)],\"valueList\":[json_toString $p(LIST)],\"valueName0\":[json_toString $p(NAME0)],\"valueName1\":[json_toString $p(NAME1)]\}"
    array unset p
  }
  return "\{\"datapoints\":\[[join $dps ,]\],\"variables\":\[[join $svs ,]\]\}"
}

proc programs_detail { } {
  global V2_QUERY
  v2_requireLevel ADMIN
  if { "targets=1" eq $V2_QUERY || "targets=conditions" eq $V2_QUERY } then {
    v2_respondJson [programs_targets [expr { "targets=1" eq $V2_QUERY ? "actions" : "conditions" }]]
    return
  }
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
