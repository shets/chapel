var D = [1..6];

var Perm: [D] index(D);

var A, B: [i in D] float = i;

Perm(1) = 2;
Perm(2) = 1;
Perm(3) = 3;
Perm(4) = 5;
Perm(5) = 6;
Perm(6) = 4;

writeln("B is: ", B);
writeln("Perm is: ", Perm);

A(Perm) = B;

writeln("A is: ", A);

A = B(Perm);

writeln("A is: ", A);

