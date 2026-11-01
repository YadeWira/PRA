{ pra.inc — options shared by the whole Pascal layer.

  Every unit includes it, and after including it each one checks that range
  and overflow checking are on: if someone removes them from here, the unit
  does not compile.

  $R+ checks ARRAY indices only: pointer accesses (p[i] with p: PByte) are
  not checked. That is why all validation works on arrays, never on
  pointers. Lengths and indices are signed (SizeInt), and loops use
  High(array), which is -1 for an empty array: with $Q+, `for i := 0 to
  n - 1` with an unsigned n = 0 raises EIntOverflow. }

{$mode objfpc}
{$H+}
{$R+}
{$Q+}
{$modeswitch advancedrecords}
