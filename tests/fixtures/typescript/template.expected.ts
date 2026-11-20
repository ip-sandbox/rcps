const t1 = `a ${ a  } b`;
const t2 = `http://x // not a comment`;
const t3 = `a${ `b${c}` }d`;
const t4 = `v ${ {x:1}.x } w`;
const t5 = `o ${ { a: `}` } } p`;
const t6 = `multi
// inside template
/* also */ line`;
const t7 = `esc \` // \${ not code`;
