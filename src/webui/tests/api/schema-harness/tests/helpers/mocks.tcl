# mocks.tcl - mock bridges of the webui-api test harness (schema-harness, T012).
#
# Loaded read-only by every component test through
#   source [file normalize [file join [file dirname [info script]] .. .. schema-harness tests helpers mocks.tcl]]
#
# Provides (all state lives in ::mock::*):
#   mock::xmlrpc      scripted tclrpc.so "xmlrpc" bridge (structs, faults as Tcl return codes)
#   mock::rega_script scripted tclrega.so "rega_script"/"rega_exec" bridge (STDOUT or Tcl error)
#   mock::session     session table answering the checksid/getupl HomeMatic scripts
#   mock::http        scripted ::http::geturl for Session.login (login.htm)
#   mock::clock       frozen clock for window based logic
#   mock::cgi_env     CGI environment + stdin builder
#   mock::fs          temp root standing in for /tmp, /etc, /var
#   mock::compose     builds a document root (legacy api tree overlaid with the staged components)
#   mock::run_cgi     runs a CGI in a tclsh subprocess with all bridges mocked, returns a result dict

# Layout. The tests are written against a "generated" tree that holds one directory per component
# (<generated>/<component>/{eq3,methods,v2,...,tests}) and against the untouched legacy api tree.
#   in the repository  src/webui/tests/api/<component>/tests/...  holds the tests only. The component
#                      code is the merged tree below src/webui/www; manifest.tsv assigns every file to
#                      its component, and ::mock::init rebuilds the per-component tree from it in a
#                      temp directory (removed at exit).
#   migration staging  .migration/webui-api/generated/<component>/ holds tests and code (detected by
#                      <root>/dispatcher/homematic.cgi) and is used as is.
# The legacy tree is a snapshot of the revision pinned in LEGACY_REV (git archive) or the directory
# named by WEBUI_API_LEGACY_TREE; it is never read from the working tree, which holds the new code.
namespace eval ::mock {
  variable here [file dirname [file normalize [info script]]]
  # helpers -> tests -> schema-harness -> <tests root>
  variable tests_root [file dirname [file dirname [file dirname $here]]]
  # repository root: WEBUI_API_REPO (set by the first process, inherited by sub-processes that load a
  # copy of this file from the rebuilt component tree in /tmp), else the first ancestor that holds
  # src/webui/www/api
  variable repo $tests_root
  if {[info exists ::env(WEBUI_API_REPO)] && [file isdirectory [file join $::env(WEBUI_API_REPO) src webui www api]]} {
    set repo $::env(WEBUI_API_REPO)
  }
  while {![file isdirectory [file join $repo src webui www api]]} {
    set up [file dirname $repo]
    if {$up eq $repo} { error "mock: cannot find the repository root above $here" }
    set repo $up
  }
  set ::env(WEBUI_API_REPO) $repo
  variable generated ""
  variable legacy_root ""
  variable legacy_api ""
  variable owned_dirs {}
  variable components {dispatcher security-session event-push interface-gateway rega-model system-admin backup-cgis user-profile schema-harness}
  variable counter 0
}

proc ::mock::tmpdir {} {
  variable counter
  set base [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
  while 1 {
    set d [file join $base mockhm-[pid]-[incr counter]-[expr {int(rand()*1000000)}]]
    if {![file exists $d]} break
  }
  file mkdir $d
  # every directory made here is removed when this process exits
  lappend ::mock::owned_dirs $d
  return $d
}

# ------------------------------------------------------------------ roots (generated, legacy)
proc ::mock::readfile {path} {
  set fd [::open $path r]
  fconfigure $fd -translation binary
  set c [::read $fd]
  ::close $fd
  return $c
}

# Directory that holds src/webui/www/{api,tcl} of the pinned legacy revision.
proc ::mock::legacy_snapshot {} { return [snapshot LEGACY_REV] }

# The same for the base the OpenCCU rootfs patches were written for (PATCH_BASE_REV): the sibling repository pins its own
# Base revision, which lags behind the upstream revision of LEGACY_REV until it bumps its pin.
proc ::mock::snapshot {name} {
  variable repo
  set revfile [file join $repo src webui tests api $name]
  if {![file exists $revfile]} { error "mock: $revfile is missing (it pins a tree revision)" }
  set rev [string trim [readfile $revfile]]
  set base [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
  set user [expr {[info exists ::tcl_platform(user)] ? $::tcl_platform(user) : "u"}]
  set cache [file join $base webui-api-legacy-[string range $rev 0 11]-$user]
  if {[file exists [file join $cache .complete]]} { return $cache }
  set tmp [tmpdir]
  if {[catch {exec git -C $repo archive $rev src/webui/www/api src/webui/www/tcl | tar -x -C $tmp} msg]} {
    file delete -force $tmp
    error "mock: the legacy tree $rev is not available ($msg). Fetch the full history\
      (git fetch --unshallow) or point WEBUI_API_LEGACY_TREE at a directory that holds\
      src/webui/www/api and src/webui/www/tcl of that revision."
  }
  set fd [::open [file join $tmp .complete] w]; ::close $fd
  file delete -force $cache
  if {[catch {file rename $tmp $cache}]} {
    # another test process was faster
    file delete -force $tmp
    if {![file exists [file join $cache .complete]]} { error "mock: cannot create $cache" }
  }
  return $cache
}

# Per-component code tree rebuilt from manifest.tsv (component <TAB> relpath <TAB> repo path).
proc ::mock::build_generated {} {
  variable repo; variable tests_root; variable owned_dirs
  set g [tmpdir]
  foreach c [glob -nocomplain -directory $tests_root -types d *] {
    if {[file isdirectory [file join $c tests]]} { copytree [file join $c tests] [file join $g [file tail $c] tests] }
  }
  set manifest [file join $tests_root manifest.tsv]
  foreach line [split [readfile $manifest] "\n"] {
    if {$line eq ""} continue
    lassign [split $line "\t"] comp rel path
    set dst [file join $g $comp {*}[split $rel /]]
    file mkdir [file dirname $dst]
    file copy -force [file join $repo {*}[split $path /]] $dst
  }
  return $g
}

proc ::mock::cleanup_owned {args} {
  variable owned_dirs
  foreach d $owned_dirs { catch {file delete -force $d} }
  set owned_dirs {}
}

proc ::mock::init {} {
  variable tests_root; variable generated; variable legacy_root; variable legacy_api
  if {[info exists ::env(WEBUI_API_LEGACY_TREE)] && $::env(WEBUI_API_LEGACY_TREE) ne ""} {
    set legacy_root $::env(WEBUI_API_LEGACY_TREE)
  } else {
    set legacy_root [legacy_snapshot]
    set ::env(WEBUI_API_LEGACY_TREE) $legacy_root
  }
  set legacy_api [file join $legacy_root src webui www api]
  if {[file exists [file join $tests_root dispatcher homematic.cgi]]} {
    set generated $tests_root
  } elseif {[info exists ::env(WEBUI_API_GEN)] && [file isdirectory $::env(WEBUI_API_GEN)]} {
    set generated $::env(WEBUI_API_GEN)
  } else {
    set generated [build_generated]
    # child processes (run_cgi, test runners) reuse this tree; only this process removes it
    set ::env(WEBUI_API_GEN) $generated
  }
}

# ------------------------------------------------------------------ xmlrpc
namespace eval ::mock::xmlrpc {
  variable script [dict create]
  variable cursor [dict create]
  variable calls {}
}
proc ::mock::xmlrpc::reset {} {
  variable script; variable cursor; variable calls
  set script [dict create]; set cursor [dict create]; set calls {}
}
proc ::mock::xmlrpc::expect {method result} {
  variable script
  dict lappend script $method [list ok $result]
}
proc ::mock::xmlrpc::fault {method code message} {
  variable script
  dict lappend script $method [list fault $code $message]
}
proc ::mock::xmlrpc::calls {} { variable calls; return $calls }
proc ::mock::xmlrpc::install {} {
  proc ::xmlrpc {url method args} {
    set rc [catch {::mock::xmlrpc::call $url $method $args} res opts]
    if {$rc == 0} { return $res }
    return -options $opts $res
  }
}
proc ::mock::xmlrpc::call {url method margs} {
  variable script; variable cursor; variable calls
  lappend calls [list $url $method {*}$margs]
  if {![dict exists $script $method]} {
    return -code error "mock xmlrpc: unscripted call $method"
  }
  set entries [dict get $script $method]
  set idx 0
  if {[dict exists $cursor $method]} { set idx [dict get $cursor $method] }
  set last [expr {[llength $entries] - 1}]
  set entry [lindex $entries [expr {$idx > $last ? $last : $idx}]]
  dict set cursor $method [expr {$idx + 1}]
  switch -- [lindex $entry 0] {
    ok    { return [lindex $entry 1] }
    fault { return -code [lindex $entry 1] [lindex $entry 2] }
  }
}

# -------------------------------------------------------------- rega_script
namespace eval ::mock::rega_script {
  variable rules {}
  variable calls {}
}
proc ::mock::rega_script::reset {} {
  variable rules; variable calls
  set rules {}; set calls {}
}
proc ::mock::rega_script::expect {pattern stdout} {
  variable rules
  lappend rules [list ok $pattern $stdout]
}
proc ::mock::rega_script::fail {pattern} {
  variable rules
  lappend rules [list fail $pattern]
}
proc ::mock::rega_script::calls {} { variable calls; return $calls }
proc ::mock::rega_script::install {} {
  proc ::rega_script {script} { ::mock::rega_script::run $script }
  proc ::rega_exec   {script} { ::mock::rega_script::run $script }
  # tclrega.so also offers "rega <script words>" (e.g. rega system.Save())
  proc ::rega        {args}   { ::mock::rega_script::run [join $args " "] }
}
proc ::mock::rega_script::run {script} {
  variable rules; variable calls
  lappend calls $script
  foreach rule $rules {
    if {[string match [lindex $rule 1] $script]} {
      if {[lindex $rule 0] eq "fail"} { return -code error "mock rega_script: scripted failure" }
      return [list STDOUT [lindex $rule 2]]
    }
  }
  set sess [::mock::session::answer $script]
  if {$sess ne "NOMATCH"} { return [list STDOUT $sess] }
  return [list STDOUT ""]
}

# ------------------------------------------------------------------ session
namespace eval ::mock::session {
  variable table [dict create]
}
proc ::mock::session::reset {} { variable table; set table [dict create] }
# add sid upl ?uid? ?userName?
proc ::mock::session::add {sid upl {uid 1000} {name Admin}} {
  variable table
  dict set table $sid [list $upl $uid $name]
}
# Answers the eq3/checksid.hms and eq3/getupl.hms style scripts, NOMATCH otherwise.
proc ::mock::session::answer {script} {
  variable table
  if {![string match *GetSessionVarStr* $script]} { return NOMATCH }
  set sid ""
  regexp {var (?:_session_id_|id) = "([^"]*)";} $script -> sid
  set known [dict exists $table $sid]
  if {[string match *StrValueByIndex* $script]} {
    # session string "<uid>;<upl>": index 0 = user id, index 1 (default) = privilege level
    set idx 1
    regexp {StrValueByIndex\(";",\s*([0-9]+)\)} $script -> idx
    if {!$known} { return [expr {$idx == 0 ? "" : 0}] }
    return [lindex [dict get $table $sid] [expr {$idx == 0 ? 1 : 0}]]
  }
  return [expr {$known ? "true" : "false"}]
}

# --------------------------------------------------------------------- http
namespace eval ::mock::http {
  variable script {}
  variable calls {}
  variable n 0
}
proc ::mock::http::reset {} { variable script; variable calls; set script {}; set calls {} }
# expect code meta   (code e.g. "HTTP/1.1 302 Found", meta e.g. {Location http://x/index.htm?sid=@abc@})
proc ::mock::http::expect {code meta} { variable script; lappend script [list $code $meta] }
proc ::mock::http::calls {} { variable calls; return $calls }
proc ::mock::http::install {} {
  package require http
  proc ::http::geturl {url args} {
    return [::mock::http::geturl $url $args]
  }
  proc ::http::code {token} { upvar #0 $token s; return $s(http) }
  proc ::http::cleanup {token} { unset -nocomplain $token }
}
proc ::mock::http::geturl {url hargs} {
  variable script; variable calls; variable n
  lappend calls [list $url {*}$hargs]
  if {![llength $script]} { return -code error "mock http: unscripted request" }
  set e [lindex $script 0]
  if {[llength $script] > 1} { set script [lrange $script 1 end] }
  namespace eval ::mockhttp {}
  set tok ::mockhttp::[incr n]
  upvar #0 $tok s
  array set s [list http [lindex $e 0] meta [lindex $e 1] body ""]
  return $tok
}

# --------------------------------------------------------------------- exec
# External commands never run inside run_cgi: they are recorded and answered from rules.
namespace eval ::mock::exec {
  variable rules {}
  variable calls {}
}
proc ::mock::exec::reset {} { variable rules; variable calls; set rules {}; set calls {} }
# expect GLOBPATTERN-ON-COMMANDLINE output ; fail GLOBPATTERN message
# expect GLOB OUTPUT ?SCRIPT?   SCRIPT (optional) runs in the CGI process with the command list in $cmd,
# e.g. to create the file a downloader would have written
proc ::mock::exec::expect {pattern output {script {}}} { variable rules; lappend rules [list ok $pattern $output $script] }
# fail GLOB MESSAGE ?ERRORCODE?   (e.g. {CHILDSTATUS 1234 124} to emulate the exit status 124 of timeout)
proc ::mock::exec::fail {pattern message {errorcode NONE}} { variable rules; lappend rules [list fail $pattern $message $errorcode] }
proc ::mock::exec::calls {} { variable calls; return $calls }
proc ::mock::exec::run {cmd} {
  variable rules; variable calls
  lappend calls $cmd
  foreach r $rules {
    if {[string match [lindex $r 1] $cmd]} {
      if {[lindex $r 0] eq "fail"} {
        set ec NONE
        if {[llength $r] > 3} { set ec [lindex $r 3] }
        return -code error -errorcode $ec [lindex $r 2]
      }
      if {[llength $r] > 3 && [lindex $r 3] ne ""} { apply [list {cmd} [lindex $r 3]] $cmd }
      return [lindex $r 2]
    }
  }
  return ""
}

# -------------------------------------------------------------------- clock
namespace eval ::mock::clock { variable now "" }
proc ::mock::clock::set {t} { variable now; ::set now $t }
proc ::mock::clock::advance {s} { variable now; ::set now [expr {$now + $s}] }

# ------------------------------------------------------------------ cgi_env
namespace eval ::mock::cgi_env {}
# build METHOD ?-body s? ?-contenttype ct? ?-header {Name value}? ... ?-query q? ?-remote_addr ip?
#   ?-https 1? ?-script_name s? ?-path_info p? ?-nolength?
# returns dict {env {k v ...} stdin body}
proc ::mock::cgi_env::build {method args} {
  set body ""; set ct ""; set query ""; set headers {}; set remote ""; set https 0
  set script_name /api/homematic.cgi; set path_info ""; set nolength 0
  foreach {k v} $args {
    switch -- $k {
      -body        { set body $v }
      -contenttype { set ct $v }
      -query       { set query $v }
      -header      { lappend headers $v }
      -remote_addr { set remote $v }
      -https       { set https $v }
      -script_name { set script_name $v }
      -path_info   { set path_info $v }
      -nolength    { set nolength $v }
      default      { error "mock::cgi_env::build: unknown option $k" }
    }
  }
  set env [dict create REQUEST_METHOD $method SERVER_PROTOCOL HTTP/1.1 GATEWAY_INTERFACE CGI/1.1 \
    SCRIPT_NAME $script_name QUERY_STRING $query]
  if {$path_info ne ""} { dict set env PATH_INFO $path_info }
  if {$method eq "POST" || $body ne ""} {
    if {!$nolength} { dict set env CONTENT_LENGTH [string length [encoding convertto utf-8 $body]] }
  }
  if {$ct ne ""} { dict set env CONTENT_TYPE $ct }
  if {$remote ne ""} { dict set env REMOTE_ADDR $remote }
  if {$https} { dict set env HTTPS on }
  foreach h $headers {
    lassign $h name value
    dict set env HTTP_[string map {- _} [string toupper $name]] $value
  }
  return [dict create env $env stdin $body]
}

# ----------------------------------------------------------------------- fs
namespace eval ::mock::fs {
  variable prefixes {/tmp /etc /var /usr/local}
}
proc ::mock::fs::create {} {
  set root [::mock::tmpdir]
  foreach d {tmp/event etc/config var/tmp var/log usr/local/etc/config} { file mkdir [file join $root {*}[split $d /]] }
  return $root
}
proc ::mock::fs::destroy {root} { file delete -force $root }
proc ::mock::fs::write {root rel content} {
  set p [file join $root {*}[split $rel /]]
  file mkdir [file dirname $p]
  set fd [open $p w]
  fconfigure $fd -translation binary -encoding iso8859-1
  puts -nonewline $fd $content
  close $fd
  return $p
}
proc ::mock::fs::read {root rel} {
  set fd [open [file join $root {*}[split $rel /]] r]
  fconfigure $fd -translation binary -encoding iso8859-1
  set c [::read $fd]
  close $fd
  return $c
}

# ------------------------------------------------------------ export/import
proc ::mock::export {} {
  dict create \
    xmlrpc_script $::mock::xmlrpc::script \
    rega_rules $::mock::rega_script::rules \
    sessions $::mock::session::table \
    http_script $::mock::http::script \
    exec_rules $::mock::exec::rules \
    now $::mock::clock::now
}
proc ::mock::import {d} {
  set ::mock::xmlrpc::script [dict get $d xmlrpc_script]
  set ::mock::rega_script::rules [dict get $d rega_rules]
  set ::mock::session::table [dict get $d sessions]
  set ::mock::http::script [dict get $d http_script]
  set ::mock::exec::rules [dict get $d exec_rules]
  set ::mock::clock::now [dict get $d now]
}
proc ::mock::reset_all {} {
  ::mock::xmlrpc::reset
  ::mock::rega_script::reset
  ::mock::session::reset
  ::mock::http::reset
  ::mock::exec::reset
  set ::mock::clock::now ""
}

# ------------------------------------------------------------------ compose
proc ::mock::copytree {src dst} {
  file mkdir $dst
  foreach f [glob -nocomplain -directory $src -types f *] {
    file copy -force $f [file join $dst [file tail $f]]
  }
  foreach f [glob -nocomplain -directory $src -types f .*] {
    if {[file tail $f] in {. ..}} continue
    file copy -force $f [file join $dst [file tail $f]]
  }
  foreach d [glob -nocomplain -directory $src -types d *] {
    copytree $d [file join $dst [file tail $d]]
  }
}
# compose ?-legacy 1? ?-staged 1? ?-only {component ...}? ?-skip {component ...}?
# Returns a temp document root; the api tree is <root>/api. Staged components are
# overlaid file by file over the (read-only) legacy tree so unchanged legacy files
# keep working while staged files win.
proc ::mock::compose {args} {
  variable legacy_api; variable generated; variable components
  set legacy 1; set staged 1; set only $components; set skip {}
  foreach {k v} $args {
    switch -- $k {
      -legacy { set legacy $v }
      -staged { set staged $v }
      -only   { set only $v }
      -skip   { set skip $v }
      default { error "mock::compose: unknown option $k" }
    }
  }
  set root [tmpdir]
  set api [file join $root api]
  file mkdir $api
  if {$legacy} {
    copytree $legacy_api $api
    # the classic UI / backup CGI libraries live next to the api tree (/www/tcl/...)
    set legacy_tcl [file join [file dirname $legacy_api] tcl]
    if {[file isdirectory $legacy_tcl]} { copytree $legacy_tcl [file join $root tcl] }
  }
  if {$staged} {
    foreach c $only {
      if {$c in $skip} continue
      set cdir [file join $generated $c]
      if {![file isdirectory $cdir]} continue
      foreach e [glob -nocomplain -directory $cdir *] {
        set t [file tail $e]
        if {$t in {tests .github COPY-PLAN.md}} continue
        if {[file isdirectory $e]} {
          copytree $e [file join $api $t]
        } else {
          file copy -force $e [file join $api $t]
        }
      }
      # staged libraries that replace /www/tcl/... (see tasks.md: security-session eq3/session.tcl,
      # eq3/rega.tcl and eq3_old/* map to src/webui/www/tcl/...)
      if {$c eq "security-session"} {
        foreach {srcrel dstrel} {eq3/session.tcl tcl/eq3/session.tcl eq3/rega.tcl tcl/eq3/rega.tcl eq3_old tcl/eq3_old} {
          set s [file join $cdir {*}[split $srcrel /]]
          set d [file join $root {*}[split $dstrel /]]
          if {[file isdirectory $s]} { copytree $s $d } elseif {[file exists $s]} { file mkdir [file dirname $d]; file copy -force $s $d }
        }
      }
    }
  }
  return $root
}

# ------------------------------------------------------------------ run_cgi
# run_cgi CGIFILE ENVDICT ?-docroot dir? ?-alias /www/? ?-fsroot dir? ?-now secs? ?-cwd dir?
#   ?-setenv {k v ...}? ?-argv list?
# ENVDICT is the result of mock::cgi_env::build. The state of the mock bridges of the
# calling process is exported into the subprocess. Result dict keys:
#   status stdout stderr syslog xmlrpc_calls rega_calls http_calls
proc ::mock::run_cgi {cgi cgienv args} {
  variable here
  set docroot ""; set alias ""; set fsroot ""; set now $::mock::clock::now; set cwd ""; set setenv {}
  foreach {k v} $args {
    switch -- $k {
      -docroot { set docroot $v }
      -alias   { set alias $v }
      -fsroot  { set fsroot $v }
      -now     { set now $v }
      -cwd     { set cwd $v }
      -setenv  { set setenv $v }
      default  { error "mock::run_cgi: unknown option $k" }
    }
  }
  set tmp [tmpdir]
  set own_fs 0
  if {$fsroot eq ""} { set fsroot [fs::create]; set own_fs 1 }
  set state [export]
  dict set state now $now
  set env [dict get $cgienv env]
  if {$docroot ne ""} {
    set dr [string trimright $docroot /]/
    dict set env DOCUMENT_ROOT $dr
    if {$cwd eq ""} { set cwd [file join $docroot api] }
  }
  if {$alias ne ""} {
    dict set env DOCUMENT_ROOT $alias
  }
  foreach {k v} $setenv { dict set env $k $v }
  if {$cwd eq ""} { set cwd [file dirname $cgi] }
  set dump [file join $tmp dump.dat]
  set w {}
  append w "set ::MOCK_DUMP [list $dump]\n"
  append w "set ::MOCK_FSROOT [list $fsroot]\n"
  append w "set ::MOCK_ALIAS [list $alias]\n"
  append w "set ::MOCK_DOCROOT [list [expr {$docroot ne "" ? [string trimright $docroot /] : ""}]]\n"
  append w "source [list [file join $here mocks.tcl]]\n"
  append w "::mock::import [list $state]\n"
  append w "array unset ::env *\n"
  append w "array set ::env [list [dict create PATH $::env(PATH) {*}$env]]\n"
  append w "cd [list $cwd]\n"
  append w {
::mock::xmlrpc::install
::mock::rega_script::install
::mock::http::install
package provide HomeMatic 1.0
# tcllib md5 is not required on the test host: a stand-in backed by md5sum (the CCU has tcllib)
if {[catch {package require md5}]} {
  namespace eval ::md5 {}
  proc ::md5::md5 {args} {
    set data [lindex $args end]
    return [lindex [::__mock_exec md5sum << $data] 0]
  }
  package provide md5 2.0.7
}
rename ::load ::__mock_load
proc ::load {args} {}
proc ::mock::map {p} {
  if {$::MOCK_ALIAS ne "" && $::MOCK_DOCROOT ne "" && [string first $::MOCK_ALIAS $p] == 0} {
    return [string cat $::MOCK_DOCROOT / [string range $p [string length $::MOCK_ALIAS] end]]
  }
  # hermetic: every absolute path outside the harness temp dirs lands in the fs root
  if {[string index $p 0] eq "/" && $::MOCK_FSROOT ne ""} {
    if {[string first $::MOCK_FSROOT $p] == 0 || [string match */mockhm-* $p] ||
        [string match /dev/* $p] || [string match /proc/* $p] || [string match /usr/lib/* $p] || [string match /usr/lib64/* $p] || [string match /usr/local/lib/* $p] ||
        [string match /usr/share/* $p]} { return $p }
    return [string cat $::MOCK_FSROOT $p]
  }
  return $p
}
rename ::open ::__mock_open
set ::MOCK_PIPE 0
proc ::open {path args} {
  if {[string index $path 0] eq "|"} {
    # no real process: the command list is recorded and answered from the mock::exec rules,
    # the answer is served through a read channel on a temp file
    set words [lrange [string range $path 1 end] 0 end]
    set out [::mock::exec::run $words]
    set f [file join [file dirname $::MOCK_DUMP] pipe[incr ::MOCK_PIPE].out]
    set fd [::__mock_open $f w]
    fconfigure $fd -translation binary -encoding iso8859-1
    puts -nonewline $fd $out
    close $fd
    return [::__mock_open $f r]
  }
  set path [::mock::map $path]
  uplevel 1 [list ::__mock_open $path {*}$args]
}
rename ::source ::__mock_source
proc ::source {args} {
  set a [lreplace $args end end [::mock::map [lindex $args end]]]
  uplevel 1 [list ::__mock_source {*}$a]
}
rename ::file ::__mock_file
proc ::file {sub args} {
  switch -- $sub {
    exists - isdirectory - isfile - mkdir - delete - mtime - atime - size - readable - writable - executable - type - rename - copy - attributes {
      set m {}
      foreach a $args { lappend m [expr {[string index $a 0] eq "-" ? $a : [::mock::map $a]}] }
      set args $m
    }
  }
  uplevel 1 [list ::__mock_file $sub {*}$args]
}
rename ::exec ::__mock_exec
set ::MOCK_SYSLOG {}
proc ::exec {args} {
  set i 0
  while {[string index [lindex $args $i] 0] eq "-" && [lindex $args $i] ne "--" && $i < [llength $args]} { incr i }
  if {[lindex $args $i] eq "--"} { incr i }
  if {[lindex $args $i] eq "logger"} {
    lappend ::MOCK_SYSLOG [lrange $args [expr {$i + 1}] end]
    return ""
  }
  # no real process is ever started: scripted through mock::exec, default empty output
  return [::mock::exec::run [lrange $args $i end]]
}
if {$::mock::clock::now ne ""} {
  rename ::clock ::__mock_clock
  proc ::clock {sub args} {
    switch -- $sub {
      sec - seco - secon - second - seconds { return $::mock::clock::now }
      milliseconds { return [expr {$::mock::clock::now * 1000}] }
      microseconds { return [expr {$::mock::clock::now * 1000000}] }
    }
    uplevel 1 [list ::__mock_clock $sub {*}$args]
  }
}
proc ::mock::dump {} {
  set fd [::__mock_open $::MOCK_DUMP w]
  puts $fd [list xmlrpc_calls $::mock::xmlrpc::calls rega_calls $::mock::rega_script::calls \
    http_calls $::mock::http::calls exec_calls $::mock::exec::calls syslog $::MOCK_SYSLOG]
  close $fd
}
rename ::exit ::__mock_exit
proc ::exit {{code 0}} { ::mock::dump; flush stdout; ::__mock_exit $code }
}
  append w "set rc \[catch {::__mock_source [list $cgi]} err opts\]\n"
  append w {
if {$rc} {
  puts stderr "CGI ERROR: $err"
  puts stderr [dict get $opts -errorinfo]
  exit 1
}
exit 0
}
  set wf [file join $tmp wrapper.tcl]
  set fd [::open $wf w]
  puts -nonewline $fd $w
  close $fd
  set inf [file join $tmp stdin.dat]
  set fd [::open $inf w]
  fconfigure $fd -translation binary -encoding utf-8
  puts -nonewline $fd [dict get $cgienv stdin]
  close $fd
  set outf [file join $tmp stdout.dat]
  set errf [file join $tmp stderr.dat]
  set status 0
  # the CCU runs the CGIs in the C locale (stdin/stdout are bytes, source files are ISO-8859-1)
  set saveLC [expr {[info exists ::env(LC_ALL)] ? $::env(LC_ALL) : "__unset__"}]
  set saveLANG [expr {[info exists ::env(LANG)] ? $::env(LANG) : "__unset__"}]
  set ::env(LC_ALL) C
  set ::env(LANG) C
  if {[catch {::exec [info nameofexecutable] $wf < $inf > $outf 2> $errf} msg]} {
    if {[lindex $::errorCode 0] eq "CHILDSTATUS"} { set status [lindex $::errorCode 2] } else { set status 1 }
  }
  if {$saveLC eq "__unset__"} { unset ::env(LC_ALL) } else { set ::env(LC_ALL) $saveLC }
  if {$saveLANG eq "__unset__"} { unset ::env(LANG) } else { set ::env(LANG) $saveLANG }
  proc ::mock::slurp {f} {
    if {![file exists $f]} { return "" }
    set fd [::open $f r]
    fconfigure $fd -translation binary -encoding utf-8
    set c [::read $fd]
    close $fd
    return $c
  }
  set res [dict create status $status stdout [slurp $outf] stderr [slurp $errf] \
    syslog {} xmlrpc_calls {} rega_calls {} http_calls {} exec_calls {} fsroot $fsroot]
  if {[file exists $dump]} {
    set fd [::open $dump r]; set d [::read $fd]; close $fd
    set res [dict merge $res $d]
  }
  file delete -force $tmp
  if {$own_fs} { fs::destroy $fsroot; dict set res fsroot "" }
  return $res
}

# resolve the roots once everything above is defined
trace add execution exit enter ::mock::cleanup_owned
::mock::init
