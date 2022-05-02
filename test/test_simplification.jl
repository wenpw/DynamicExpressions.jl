include("test_params.jl")
using SymbolicRegression, Test
import SymbolicUtils: simplify, Symbolic
import Random: MersenneTwister

binary_operators = (+, -, /, *)

index_of_mult = [i for (i, op) in enumerate(binary_operators) if op == *][1]

options = Options(; default_params..., binary_operators=binary_operators)

tree = Node("x1") + Node("x1")

# Should simplify to 2*x1:
eqn = convert(Symbolic, tree, options)
eqn2 = simplify(eqn)
# Should correctly simplify to 2 x1:
@test occursin("2", "$(repr(eqn2)[1])")

# Let's convert back:
tree = convert(Node, eqn2, options)
# Make sure one of the nodes is now 2.0:
@test (tree.l.constant ? tree.l : tree.r).val == 2
# Make sure the other node is x1:
@test (!tree.l.constant ? tree.l : tree.r).feature == 1

# Finally, let's try simplifying a product, and ensure
# that SymbolicUtils does not convert it to a power:
tree = Node("x1") * Node("x1")
eqn = convert(Symbolic, tree, options)
@test repr(eqn) == "x1*x1"
# Test converting back:
tree_copy = convert(Node, eqn, options)
@test repr(tree_copy) == "(x1 * x1)"

# Let's test a much more complex function,
# with custom operators, and unary operators:
x1, x2, x3 = Node("x1"), Node("x2"), Node("x3")
pow_abs(x, y) = abs(x) ^ y
custom_cos(x) = cos(x)^2

# Define for Node (usually these are done internally to Options)
pow_abs(l::Node, r::Node)::Node = (l.constant && r.constant) ? Node(pow_abs(l.val, r.val)::AbstractFloat) : Node(5, l, r)
pow_abs(l::Node, r::AbstractFloat)::Node = l.constant ? Node(pow_abs(l.val, r)::AbstractFloat) : Node(5, l, r)
pow_abs(l::AbstractFloat, r::Node)::Node = r.constant ? Node(pow_abs(l, r.val)::AbstractFloat) : Node(5, l, r)
custom_cos(x::Node)::Node = x.constant ? Node(custom_cos(x.val)::AbstractFloat) : Node(1, x)

options = Options(;
    binary_operators=(+, *, -, /, pow_abs),
    unary_operators=(custom_cos, exp, sin),
)
tree = (((x2 + x2) * ((-0.5982493 / pow_abs(x1, x2)) / -0.54734415)) + (sin(custom_cos(sin(1.2926733 - 1.6606787) / sin(((0.14577048 * x1) + ((0.111149654 + x1) - -0.8298334)) - -1.2071426)) * (custom_cos(x3 - 2.3201916) + ((x1 - (x1 * x2)) / x2))) / (0.14854191 - ((custom_cos(x2) * -1.6047639) - 0.023943262))))
# We use `index_functions` to avoid converting the custom operators into the primitives.
eqn = convert(Symbolic, tree, options, index_functions=true)

tree_copy = convert(Node, eqn, options)
# Too difficult to check the representation, so we check by evaluation:
N = 100
X = rand(MersenneTwister(0), 3, N)
output1, flag1 = evalTreeArray(tree, X, options)
output2, flag2 = evalTreeArray(tree_copy, X, options)

isapprox(output1, output2, atol=1e-5 * N)