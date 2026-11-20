const char *s = "// not /* a comment */"; // real
char c1 = '\''; /* r */
char c2 = '"'; // r
const char *t = "a\"//b"; /* r */
const char *u = "line \
cont // still string";
