# patchapply.tcl - patch-apply gate of the webui-api test harness (T253c, NFR-056, BD-18).
#
# The OpenCCU packaging patches (buildroot-external/package/openccu-base/rootfs-patches) stay
# downstream and are applied with `patch -p1` to the Base rootfs. This helper proves that they
# keep applying to the staged files. Everything happens on a temporary copy; neither the
# repository nor the OpenCCU directory is ever modified.
#
# API
#   patchapply::patchdir                   OPENCCU_PATCH_DIR or the default directory
#   patchapply::compose_legacy             temp tree with www/api and www/tcl copied from src/webui/www
#   patchapply::compose_patchbase          the same for the base revision the patches were written for (PATCH_BASE_REV)
#   patchapply::compose_staged             the same tree overlaid with every staged component file
#   patchapply::apply_all TREE ?DIR?       ordered list of {number OK|FAIL}, or "skip" without DIR
#   patchapply::report RESULTS legacy|staged   'legacy tree: N OK' or 'patch NNNN: OK|FAIL' lines
#   patchapply::filter_sections TEXT       keep only the www/api/ and www/tcl/ file sections

namespace eval ::patchapply {
  variable here [file dirname [file normalize [info script]]]
  if {![info exists ::mock::generated]} { source [file join $here mocks.tcl] }
  # staged files: the per-component tree of mocks.tcl; legacy files: the pinned legacy snapshot
  variable generated $::mock::generated
  variable repo $::mock::repo
  variable legacy_www [file join $::mock::legacy_root src webui www]
  variable numbers {0001 0031 0038 0044 0054 0057 0104 0109 0131 0163 0164 0203 0205}
  variable components {dispatcher security-session event-push interface-gateway rega-model system-admin backup-cgis user-profile}
  variable skip_top {tests schema v2 rega .github COPY-PLAN.md}
  variable counter 0
}

proc ::patchapply::patchdir {} {
  if {[info exists ::env(OPENCCU_PATCH_DIR)] && $::env(OPENCCU_PATCH_DIR) ne ""} {
    return $::env(OPENCCU_PATCH_DIR)
  }
  return [file join $::env(HOME) dev OpenCCU buildroot-external package openccu-base rootfs-patches]
}

proc ::patchapply::tmpdir {} {
  variable counter
  set base [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
  while 1 {
    set d [file join $base patchgate-[pid]-[incr counter]-[expr {int(rand()*1000000)}]]
    if {![file exists $d]} break
  }
  file mkdir $d
  # removed when the process exits (see ::mock::cleanup_owned)
  lappend ::mock::owned_dirs $d
  return $d
}

proc ::patchapply::copytree {src dst} {
  file mkdir $dst
  foreach f [glob -nocomplain -directory $src -types f *] { file copy -force $f [file join $dst [file tail $f]] }
  foreach f [glob -nocomplain -directory $src -types f .*] { file copy -force $f [file join $dst [file tail $f]] }
  foreach d [glob -nocomplain -directory $src -types d *] { copytree $d [file join $dst [file tail $d]] }
}

# The real build (prepare_patch_input.sh) canonicalises www/tcl/eq3/rega.tcl to LF before patching.
proc ::patchapply::normalize {tree} {
  set f [file join $tree www tcl eq3 rega.tcl]
  if {![file exists $f]} return
  set fd [open $f rb]; set d [read $fd]; close $fd
  set d [string map [list "\r\n" "\n"] $d]
  set fd [open $f wb]; puts -nonewline $fd $d; close $fd
}

proc ::patchapply::compose_legacy {} {
  variable legacy_www
  set tree [tmpdir]
  foreach s {api tcl} { copytree [file join $legacy_www $s] [file join $tree www $s] }
  normalize $tree
  return $tree
}

# the tree the patches were WRITTEN for (PATCH_BASE_REV), not the tree of LEGACY_REV
proc ::patchapply::compose_patchbase {} {
  set www [file join [::mock::snapshot PATCH_BASE_REV] src webui www]
  set tree [tmpdir]
  foreach s {api tcl} { copytree [file join $www $s] [file join $tree www $s] }
  normalize $tree
  return $tree
}

proc ::patchapply::put {src dst} {
  file mkdir [file dirname $dst]
  file copy -force $src $dst
}

proc ::patchapply::overlay {cdir dst} {
  variable skip_top
  foreach e [glob -nocomplain -directory $cdir *] {
    set t [file tail $e]
    if {$t in $skip_top} continue
    if {[file isdirectory $e]} { copytree $e [file join $dst $t] } else { put $e [file join $dst $t] }
  }
}

proc ::patchapply::compose_staged {} {
  variable generated; variable components
  set tree [compose_legacy]
  set api [file join $tree www api]
  set tcl [file join $tree www tcl]
  foreach c $components {
    set cdir [file join $generated $c]
    if {![file isdirectory $cdir]} continue
    if {$c eq "security-session"} {
      # eq3_old/* and eq3/{session,rega}.tcl live below www/tcl, everything else below www/api
      foreach e [glob -nocomplain -directory $cdir *] {
        set t [file tail $e]
        if {$t in {tests schema v2 rega .github COPY-PLAN.md eq3_old}} continue
        if {$t eq "eq3"} {
          foreach f [glob -nocomplain -directory $e -types f *] {
            if {[file tail $f] in {session.tcl rega.tcl}} {
              put $f [file join $tcl eq3 [file tail $f]]
            } else {
              put $f [file join $api eq3 [file tail $f]]
            }
          }
        } elseif {[file isdirectory $e]} {
          copytree $e [file join $api $t]
        } else {
          put $e [file join $api $t]
        }
      }
      if {[file isdirectory [file join $cdir eq3_old]]} { copytree [file join $cdir eq3_old] [file join $tcl eq3_old] }
    } else {
      overlay $cdir $api
    }
  }
  normalize $tree
  return $tree
}

# keep only the file sections whose path starts with www/api/ or www/tcl/
proc ::patchapply::filter_sections {text} {
  set lines [split $text "\n"]
  # a final empty element only stems from the terminating newline
  if {[lindex $lines end] eq ""} { set lines [lrange $lines 0 end-1] }
  set n [llength $lines]
  set out {}
  set keep 0
  for {set i 0} {$i < $n} {incr i} {
    set l [lindex $lines $i]
    if {[string match {--- *} $l] && $i + 1 < $n && [string match {+++ *} [lindex $lines [expr {$i + 1}]]]} {
      set path [lindex [split [string range $l 4 end] "\t"] 0]
      set keep [regexp {^a/www/(api|tcl)/} $path]
    }
    if {$keep} { lappend out $l }
  }
  if {![llength $out]} { return "" }
  return "[join $out "\n"]\n"
}

proc ::patchapply::apply_all {tree {dir ""}} {
  variable numbers
  if {$dir eq ""} { set dir [patchdir] }
  if {![file isdirectory $dir]} { return skip }
  set work [tmpdir]
  set results {}
  foreach n $numbers {
    set pf [lindex [lsort [glob -nocomplain -directory $dir $n-*.patch]] 0]
    if {$pf eq ""} { lappend results [list $n FAIL]; continue }
    set fd [open $pf rb]; set text [read $fd]; close $fd
    set filtered [filter_sections $text]
    set tmp [file join $work $n.patch]
    set fd [open $tmp wb]; puts -nonewline $fd $filtered; close $fd
    # dry run first: a patch that does not apply cleanly leaves the tree untouched, like an
    # aborted build step, so that the later patches are judged on their own
    if {[catch {exec patch -p1 -d $tree --dry-run --no-backup-if-mismatch -s -i $tmp 2>@1}]} {
      lappend results [list $n FAIL]
    } elseif {[catch {exec patch -p1 -d $tree --no-backup-if-mismatch -s -i $tmp 2>@1}]} {
      lappend results [list $n FAIL]
    } else {
      lappend results [list $n OK]
    }
  }
  file delete -force $work
  return $results
}

proc ::patchapply::report {results kind} {
  if {$results eq "skip"} { return "skipped: patch directory not found" }
  if {$kind eq "legacy"} {
    set ok 0
    foreach r $results { if {[lindex $r 1] eq "OK"} { incr ok } }
    return "legacy tree: $ok OK"
  }
  set lines {}
  foreach r $results { lappend lines "patch [lindex $r 0]: [lindex $r 1]" }
  return [join $lines "\n"]
}
