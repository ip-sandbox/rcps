const t1 = `a ${ a /* c */ } b`; // c1
const t2 = `http://x // not a comment`; // c2
const t3 = `a${ `b${c}` }d`; // c3
const t4 = `v ${ {x:1}.x } w`; // c4
const t5 = `o ${ { a: `}` } } p`; // c5
const t6 = `multi
// inside template
/* also */ line`; // c6
const t7 = `esc \` // \${ not code`; // c7
