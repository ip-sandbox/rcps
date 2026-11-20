const r1 = /\/\//g; // c1
const r2 = /[/]/; // c2
const x = a / b / c; // c3
function f() { return /re/; } // c4
const r3 = (/re/); // c5
const r4 = x.match(/a\/*b/i) /* c6 */ + 1;
const d = (a) / 2 / 3; // c7
const e = a /* mid */ / b; // c8
