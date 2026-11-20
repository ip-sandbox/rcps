auto a = R"x( */ // " )x"; // c1
auto b = u8R"(/* no )" /* c2 */
auto c = LR"d(//)d"; // c3
auto e = uR"(//)"; auto f = UR"(//)"; // c4
auto g = R"(
// multi
/* line */
)"; // c5
