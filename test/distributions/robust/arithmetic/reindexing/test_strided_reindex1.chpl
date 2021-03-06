use driver;

const D: domain(2,int,true) dmapped Dist2D = {1..24 by 2, 1..24 by 2};

var A: [D] int;

var AA: [101..124 by 2] => A(1..24 by 2, 3);

forall i in D do A(i) = 1;

forall e in AA do e = 0;

writeln(A);
writeln(AA);

writeln(AA.domain);
