{ ppa.inc — options shared by the whole Pascal layer.

  Every unit includes it, and after including it each one checks that range
  and overflow checking are on: if someone removes them from here, the unit
  does not compile.

  Taken from PJA (measured there on 25/09/2026):
    - $R+ checks ARRAY indices. Pointer accesses (p[i] with p: PByte) are NOT
      checked, so all validation works on arrays, never on pointers.
    - with $Q+, `for i := 0 to n - 1` with unsigned n and n = 0 raises
      EIntOverflow. Lengths and indices are signed (SizeInt), and loops use
      High(array), which is -1 for an empty array. }

{$mode objfpc}
{$H+}
{$R+}
{$Q+}
{$modeswitch advancedrecords}
{ nested procedures as values: ppathreads.ParallelFor takes them }
{$modeswitch nestedprocvars}
