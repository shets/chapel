use BlockDist;

config const tasksPerLocale=2, m=8, iters=100, verbose=false;

const Dist = new dist(new Block(rank=1, boundingBox=[1..m],
                                dataParTasksPerLocale=tasksPerLocale));
const Dom: domain(1) distributed Dist = [1..m];
var A, B: [Dom] real;

var s$: sync int = 1;

forall (a,b) in (A,B) {
  const ss = s$;
  a = ss;
  b = ss + 1;
  s$ = ss + 2;
}

if verbose {
  writeln(A);
  writeln(B);
}

for i in 1..iters do
  write(max reduce [(a,b) in (A,B)] abs(a + b));
writeln();
