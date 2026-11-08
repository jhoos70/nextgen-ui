# golden.tcl - golden-fixture runner of the webui-api test harness (schema-harness, T014).
#
# NFR-045: the v1 wire contract is frozen. Fixtures are {request, mock_script, expected_response}
# per registry method ("Namespace.method.json"). They are seeded in memory from the 182-entry
# registry (methods.conf ARGUMENTS) so no undeclared file has to be written; a curated override
# for a method may be dropped into tests/fixtures/<Namespace.method>.json as a Tcl dict
# (keys request / mock_script) and wins over the seed.
#
# API
#   golden::registry                    dict name -> {LEVEL .. SCRIPT_FILE .. METHOD_FILE .. INFO .. ARGUMENTS ..}
#   golden::fixtures                    list of fixture dicts (method request mock_script expected_response)
#   golden::fixture NAME                one fixture dict
#   golden::fixture_filename NAME       "Namespace.method.json"
#   golden::capture FX ?-candidate legacy|staged?   replay through homematic.cgi, return body bytes
#   golden::expected FX                 the frozen answer (legacy as-is dispatcher stub)
#   golden::diff A B                    "" or "first difference at byte N: ..."
#   golden::compare_all ?-candidate legacy|staged? ?-only {names}?   list of "method: diff" mismatches

namespace eval ::golden {
  variable here [file dirname [file normalize [info script]]]
  # helpers -> tests -> schema-harness
  variable tests [file dirname $here]
  variable fixture_dir [file join $tests fixtures]
  variable registry_cache {}
  variable roots [dict create]
  variable expected_cache [dict create]
  variable sid AbCdEf1234
}

# ----------------------------------------------------------------- registry
# registry ?staged?  the v1 registry (default, the frozen contract) or the corrected staged
# registry of the dispatcher component (UTF-8)
proc ::golden::registry {{staged 0}} {
  variable registry_cache
  variable generated_dir
  if {$staged} {
    set f [file join $::mock::generated dispatcher methods.conf]
    set fd [open $f r]
    # the staged registry keeps the ISO-8859-1 encoding of the legacy file (NFR-056)
    fconfigure $fd -translation binary -encoding iso8859-1
    set c [read $fd]
    close $fd
    set reg [dict create]
    foreach {name body} $c { dict set reg $name $body }
    return $reg
  }
  if {$registry_cache ne ""} { return $registry_cache }
  set f [file join $::mock::legacy_api methods.conf]
  set fd [open $f r]
  fconfigure $fd -translation binary -encoding iso8859-1
  set c [read $fd]
  close $fd
  set reg [dict create]
  # entries are "name { key value ... }" pairs of a Tcl list, as array set reads them
  foreach {name body} $c {
    dict set reg $name $body
  }
  set registry_cache $reg
  return $reg
}

proc ::golden::fixture_filename {name} { return $name.json }

# Makes the bytes reproducible: temp dir names and the source line numbers of v1 Tcl
# stack traces (errorInfo, "(file \"...\" line N)") are replaced, so a staged copy of a
# method script with different comment lengths still compares byte-equal.
proc ::golden::normalize {s {canonical 0}} {
  set s [regsub -all {mockhm-[0-9]+-[0-9]+-[0-9]+} $s mockhm-X]
  set s [regsub -all {line [0-9]+\)} $s {line N)}]
  # v1 internal errors carry the Tcl stack trace (errorInfo) which quotes source text and line
  # numbers of the method script: only the first message line is compared byte for byte
  set out ""; set pos 0
  while {[regexp -indices -start $pos {"message": "internal error[^\n]*} $s m]} {
    lassign $m a b
    append out [string range $s $pos [expr {$a - 1}]]
    set line [string range $s $a $b]
    set k [string first {\n    while executing} $line]
    if {$k >= 0} { set line "[string range $line 0 [expr {$k - 1}]]\"" }
    # the hardened dispatcher answers "internal error (ref: <cid>)" instead of the Tcl error text
    # (deliberate change SP005): the internal error class is what the frozen contract keeps
    if {$canonical} { set line {"message": "internal error"} }
    append out $line
    set pos [expr {$b + 1}]
  }
  append out [string range $s $pos end]
  return $out
}

# ----------------------------------------------------------------- seeding
proc ::golden::arg_value {name} {
  variable sid
  switch -- $name {
    _session_id_ { return $sid }
    interface    { return BidCos-RF }
    address      { return NEQ0123456:1 }
    channelAddress { return NEQ0123456:1 }
    teamAddress  { return *NEQ0123457 }
    peerAddress  { return NEQ0123457:1 }
    paramsetKey  { return VALUES }
    name         { return system.listMethods }
    key          { return golden }
    id           { return 1234 }
    testId       { return "2026-10-13 12:00:00" }
    file         { return /etc/config/userAckSecurityHint }
    default      { return 1 }
  }
}

proc ::golden::json_string {s} {
  return \"[string map [list \\ \\\\ \" \\\" \n \\n \r \\r \t \\t] $s]\"
}

proc ::golden::seed {name} {
  variable sid
  set e [dict get [registry] $name]
  set ps {}
  foreach a [dict get $e ARGUMENTS] {
    lappend ps [json_string $a]:[json_string [arg_value $a]]
  }
  set request "\{\"method\":[json_string $name],\"params\":\{[join $ps ,]\},\"id\":1\}"
  set mock_script [dict create sessions [list [list $sid 8 1000 Admin]] xmlrpc {} rega {}]
  return [dict create method $name request $request mock_script $mock_script expected_response {}]
}

proc ::golden::fixtures {} {
  set out {}
  foreach name [lsort [dict keys [registry]]] { lappend out [fixture $name] }
  return $out
}

proc ::golden::fixture {name} {
  variable fixture_dir
  set fx [seed $name]
  set over [file join $fixture_dir [fixture_filename $name]]
  if {[file exists $over]} {
    set fd [open $over r]; set c [read $fd]; close $fd
    set fx [dict merge $fx $c]
  }
  return $fx
}

# ------------------------------------------------------------------ replay
proc ::golden::root {candidate} {
  variable roots
  if {![dict exists $roots $candidate]} {
    switch -glob -- $candidate {
      legacy { set r [::mock::compose -staged 0] }
      staged { set r [::mock::compose] }
      only:* { set r [::mock::compose -only [split [string range $candidate 5 end] ,]] }
      default { error "golden: unknown candidate $candidate" }
    }
    dict set roots $candidate $r
  }
  return [dict get $roots $candidate]
}

proc ::golden::cleanup {} {
  variable roots
  dict for {c r} $roots { file delete -force $r }
  set roots [dict create]
}

proc ::golden::capture {fx args} {
  set candidate legacy
  foreach {k v} $args {
    switch -- $k {
      -candidate { set candidate $v }
      default { error "golden::capture: unknown option $k" }
    }
  }
  set root [root $candidate]
  set ms [dict get $fx mock_script]
  ::mock::reset_all
  ::mock::xmlrpc::reset
  foreach s [expr {[dict exists $ms sessions] ? [dict get $ms sessions] : {}}] {
    ::mock::session::add {*}$s
  }
  if {[dict exists $ms xmlrpc]} {
    foreach x [dict get $ms xmlrpc] { ::mock::xmlrpc::expect [lindex $x 0] [lindex $x 1] }
  }
  if {[dict exists $ms rega]} {
    foreach r [dict get $ms rega] { ::mock::rega_script::expect [lindex $r 0] [lindex $r 1] }
  }
  set fs [::mock::fs::create]
  ::mock::fs::write $fs etc/config/InterfacesList.xml \
    "<interfaces><ipc><name>BidCos-RF</name><url>xmlrpc_bin://127.0.0.1:2001</url><info>BidCos-RF</info></ipc></interfaces>"
  set env [::mock::cgi_env::build POST -body [dict get $fx request] -contenttype application/json]
  set res [::mock::run_cgi [file join $root api homematic.cgi] $env -docroot $root -alias /www/ -fsroot $fs -now 1700000000]
  ::mock::fs::destroy $fs
  # strip the CGI header block; temp dir names are normalised so the bytes are reproducible
  set out [normalize [dict get $res stdout] 1]
  set i [string first "\n\n" $out]
  set j [string first "\r\n\r\n" $out]
  if {$j >= 0 && ($i < 0 || $j < $i)} { return [string range $out [expr {$j + 4}] end] }
  if {$i >= 0} { return [string range $out [expr {$i + 2}] end] }
  return $out
}

proc ::golden::expected {fx} {
  variable expected_cache
  set key [dict get $fx method]|[dict get $fx request]|[dict get $fx mock_script]
  if {[dict exists $expected_cache $key]} { return [dict get $expected_cache $key] }
  set out [capture $fx -candidate legacy]
  dict set expected_cache $key $out
  return $out
}

# ------------------------------------------------------------------- diff
proc ::golden::diff {a b} {
  if {$a eq $b} { return "" }
  set n [expr {min([string length $a], [string length $b])}]
  for {set i 0} {$i < $n} {incr i} {
    if {[string index $a $i] ne [string index $b $i]} break
  }
  return "first difference at byte $i: \"[string index $a $i]\" vs \"[string index $b $i]\""
}

proc ::golden::compare_all {args} {
  set candidate legacy; set only {}
  foreach {k v} $args {
    switch -- $k {
      -candidate { set candidate $v }
      -only { set only $v }
      default { error "golden::compare_all: unknown option $k" }
    }
  }
  set bad {}
  foreach fx [fixtures] {
    set m [dict get $fx method]
    if {[llength $only] && $m ni $only} continue
    set d [diff [expected $fx] [capture $fx -candidate $candidate]]
    if {$d ne ""} { lappend bad "$m: $d" }
  }
  return $bad
}

# ----------------------------------------------------------------- generic calls
# Shared by the component tests. Options (all optional):
#   -candidate legacy|staged|only:comp,comp   document root composition (default staged)
#   -sessions {{sid upl uid name} ...}        session table (default: AbCdEf1234 ADMIN)
#   -xmlrpc {{method result} ...}  -fault {{method code msg} ...}  -rega {{glob stdout} ...}
#   -regafail {glob ...}  -exec {{glob out} ...}  -execfail {{glob msg} ...}  -http {{code meta} ...}
#   -files {relpath content ...}              seeded below the fs root (e.g. etc/config/x)
#   -fs ROOT                                  caller supplied fs root (kept; else temp, destroyed)
#   -setenv {k v ...}  -now secs  -remote_addr ip  -header {Name value} (repeatable)
#   -interfaces 0|1                           seed InterfacesList.xml (default 1)
proc ::golden::prepare {opts} {
  set o [dict create -candidate staged -sessions [list [list $::golden::sid 8 1000 Admin]] -xmlrpc {} -fault {} \
    -rega {} -regafail {} -exec {} -execfail {} -http {} -files {} -fs {} -setenv {} -now 1700000000 \
    -remote_addr {} -headers {} -interfaces 1 -method POST -contenttype application/json -query {} -body {}]
  foreach {k v} $opts {
    if {$k eq "-header"} { dict lappend o -headers $v; continue }
    if {![dict exists $o $k]} { error "golden: unknown option $k" }
    dict set o $k $v
  }
  ::mock::reset_all
  foreach s [dict get $o -sessions] { ::mock::session::add {*}$s }
  foreach x [dict get $o -xmlrpc] { ::mock::xmlrpc::expect [lindex $x 0] [lindex $x 1] }
  foreach x [dict get $o -fault] { ::mock::xmlrpc::fault {*}$x }
  foreach r [dict get $o -regafail] { ::mock::rega_script::fail $r }
  foreach r [dict get $o -rega] { ::mock::rega_script::expect [lindex $r 0] [lindex $r 1] }
  foreach r [dict get $o -exec] { ::mock::exec::expect {*}$r }
  foreach r [dict get $o -execfail] { ::mock::exec::fail {*}$r }
  foreach r [dict get $o -http] { ::mock::http::expect [lindex $r 0] [lindex $r 1] }
  set fs [dict get $o -fs]
  set own 0
  if {$fs eq ""} { set fs [::mock::fs::create]; set own 1 }
  if {[dict get $o -interfaces] && ![file exists [file join $fs etc config InterfacesList.xml]]} {
    ::mock::fs::write $fs etc/config/InterfacesList.xml \
      "<interfaces><ipc><name>BidCos-RF</name><url>xmlrpc_bin://127.0.0.1:2001</url><info>BidCos-RF</info></ipc></interfaces>"
  }
  foreach {rel c} [dict get $o -files] { ::mock::fs::write $fs $rel $c }
  dict set o fs $fs
  dict set o own $own
  return $o
}

proc ::golden::finish {o res} {
  if {[dict get $o own]} { ::mock::fs::destroy [dict get $o fs] }
  set out [normalize [dict get $res stdout]]
  dict set res stdout $out
  set body $out
  set i [string first "\n\n" $out]
  set j [string first "\r\n\r\n" $out]
  if {$j >= 0 && ($i < 0 || $j < $i)} { set body [string range $out [expr {$j + 4}] end]; dict set res headers [string range $out 0 [expr {$j - 1}]] } \
  elseif {$i >= 0} { set body [string range $out [expr {$i + 2}] end]; dict set res headers [string range $out 0 [expr {$i - 1}]] } \
  else { dict set res headers "" }
  dict set res body $body
  return $res
}

# call METHOD PARAMS-JSON-OBJECT-BODY ?options?   -> result dict of mock::run_cgi plus body/headers
# PARAMS is a Tcl dict of name value (strings), turned into the JSON params object.
proc ::golden::call {method params args} {
  set o [prepare $args]
  set ps {}
  dict for {k v} $params { lappend ps [json_string $k]:[json_string $v] }
  set req "\{\"method\":[json_string $method],\"params\":\{[join $ps ,]\},\"id\":1\}"
  return [call_raw $req $o]
}

proc ::golden::call_raw {request o} {
  set root [root [dict get $o -candidate]]
  set env [::mock::cgi_env::build [dict get $o -method] -body $request -contenttype [dict get $o -contenttype] \
    -query [dict get $o -query] -remote_addr [dict get $o -remote_addr]]
  foreach h [dict get $o -headers] {
    dict set env env HTTP_[string map {- _} [string toupper [lindex $h 0]]] [lindex $h 1]
  }
  set res [::mock::run_cgi [file join $root api homematic.cgi] $env -docroot $root -alias /www/ \
    -fsroot [dict get $o fs] -now [dict get $o -now] -setenv [dict get $o -setenv]]
  return [finish $o $res]
}

# tcl SCRIPT ?options?  runs SCRIPT as a CGI-like driver in the composed doc root (cwd = <root>/api,
# DOCUMENT_ROOT=/www/ mapped to the root). Typical script: source [file join $env(DOCUMENT_ROOT) api/eq3/ipc.tcl]
proc ::golden::tcl {script args} {
  set o [prepare $args]
  set root [root [dict get $o -candidate]]
  set d [::mock::tmpdir]
  set f [file join $d driver.tcl]
  set fd [open $f w]; puts $fd "load tclrpc.so\nload tclrega.so\n$script"; close $fd
  set env [::mock::cgi_env::build [dict get $o -method] -remote_addr [dict get $o -remote_addr]]
  set res [::mock::run_cgi $f $env -docroot $root -alias /www/ -fsroot [dict get $o fs] \
    -now [dict get $o -now] -setenv [dict get $o -setenv]]
  file delete -force $d
  return [finish $o $res]
}

# cgi RELPATH ?options?  runs a CGI below the composed api tree (e.g. backup/login.cgi) with the
# working directory set to the CGI's own directory, as lighttpd does. Options as for call, plus
# -method (default GET), -query, -body.
proc ::golden::cgi {relpath args} {
  set o [prepare [concat [list -method GET -contenttype {}] $args]]
  set root [root [dict get $o -candidate]]
  set cgi [file join $root api {*}[split $relpath /]]
  set env [::mock::cgi_env::build [dict get $o -method] -body [dict get $o -body] -contenttype [dict get $o -contenttype] \
    -query [dict get $o -query] -remote_addr [dict get $o -remote_addr] -script_name /api/$relpath]
  foreach h [dict get $o -headers] {
    dict set env env HTTP_[string map {- _} [string toupper [lindex $h 0]]] [lindex $h 1]
  }
  set res [::mock::run_cgi $cgi $env -docroot $root -alias /www/ -fsroot [dict get $o fs] \
    -now [dict get $o -now] -setenv [dict get $o -setenv] -cwd [file dirname $cgi]]
  return [finish $o $res]
}
