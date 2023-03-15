module SimplifyEquationModule

import ..EquationModule: Node, copy_node
import ..OperatorEnumModule: AbstractOperatorEnum
import ..UtilsModule: isbad, isgood

# Simplify tree
function combine_operators(
    tree::Node{T},
    operators::AbstractOperatorEnum,
    id_map::IdDict{Node{T},Node{T}}=IdDict{Node{T},Node{T}}(),
)::Node{T} where {T}
    # NOTE: (const (+*-) const) already accounted for. Call simplify_tree before.
    # ((const + var) + const) => (const + var)
    # ((const * var) * const) => (const * var)
    # ((const - var) - const) => (const - var)
    # (want to add anything commutative!)
    # TODO - need to combine plus/sub if they are both there.
    get!(id_map, tree) do
        if tree.degree == 0
            return tree
        elseif tree.degree == 1
            tree.l = combine_operators(tree.l, operators, id_map)
        elseif tree.degree == 2
            tree.l = combine_operators(tree.l, operators, id_map)
            tree.r = combine_operators(tree.r, operators, id_map)
        end

        top_level_constant = tree.degree == 2 && (tree.l.constant || tree.r.constant)
        if tree.degree == 2 &&
            (operators.binops[tree.op] == (*) || operators.binops[tree.op] == (+)) &&
            top_level_constant
            op = tree.op
            # Put the constant in r. Need to assume var in left for simplification assumption.
            if tree.l.constant
                tmp = tree.r
                tree.r = tree.l
                tree.l = tmp
            end
            topconstant = tree.r.val::T
            # Simplify down first
            below = tree.l
            if below.degree == 2 && below.op == op
                if below.l.constant
                    tree = below
                    tree.l.val = operators.binops[op](tree.l.val::T, topconstant)
                elseif below.r.constant
                    tree = below
                    tree.r.val = operators.binops[op](tree.r.val::T, topconstant)
                end
            end
        end

        if tree.degree == 2 && operators.binops[tree.op] == (-) && top_level_constant
            # Currently just simplifies subtraction. (can't assume both plus and sub are operators)
            # Not commutative, so use different op.
            if tree.l.constant
                if tree.r.degree == 2 && operators.binops[tree.r.op] == (-)
                    if tree.r.l.constant
                        #(const - (const - var)) => (var - const)
                        l = tree.l
                        r = tree.r
                        simplified_const = -(l.val::T - r.l.val::T) #neg(sub(l.val, r.l.val))
                        tree.l = tree.r.r
                        tree.r = l
                        tree.r.val = simplified_const
                    elseif tree.r.r.constant
                        #(const - (var - const)) => (const - var)
                        l = tree.l
                        r = tree.r
                        simplified_const = l.val::T + r.r.val::T #plus(l.val, r.r.val)
                        tree.r = tree.r.l
                        tree.l.val = simplified_const
                    end
                end
            else #tree.r.constant is true
                if tree.l.degree == 2 && operators.binops[tree.l.op] == (-)
                    if tree.l.l.constant
                        #((const - var) - const) => (const - var)
                        l = tree.l
                        r = tree.r
                        simplified_const = l.l.val::T - r.val::T#sub(l.l.val, r.val)
                        tree.r = tree.l.r
                        tree.l = r
                        tree.l.val = simplified_const
                    elseif tree.l.r.constant
                        #((var - const) - const) => (var - const)
                        l = tree.l
                        r = tree.r
                        simplified_const = r.val::T + l.r.val::T #plus(r.val, l.r.val)
                        tree.l = tree.l.l
                        tree.r.val = simplified_const
                    end
                end
            end
        end
        return tree
    end
end

# Simplify tree
function simplify_tree(
    tree::Node{T},
    operators::AbstractOperatorEnum,
    id_map::IdDict{Node{T},Node{T}}=IdDict{Node{T},Node{T}}(),
)::Node{T} where {T}
    get!(id_map, tree) do
        if tree.degree == 1
            tree.l = simplify_tree(tree.l, operators, id_map)
            if tree.l.degree == 0 && tree.l.constant
                l = tree.l.val::T
                if isgood(l)
                    out = operators.unaops[tree.op](l)
                    if isbad(out)
                        return tree
                    end
                    return Node(T; val=convert(T, out))
                end
            end
        elseif tree.degree == 2
            tree.l = simplify_tree(tree.l, operators, id_map)
            tree.r = simplify_tree(tree.r, operators, id_map)
            constantsBelow = (
                tree.l.degree == 0 &&
                tree.l.constant &&
                tree.r.degree == 0 &&
                tree.r.constant
            )
            if constantsBelow
                # NaN checks:
                l = tree.l.val::T
                r = tree.r.val::T
                if isbad(l) || isbad(r)
                    return tree
                end

                # Actually compute:
                out = operators.binops[tree.op](l, r)
                if isbad(out)
                    return tree
                end
                return Node(T; val=convert(T, out))
            end
        end
        return tree
    end
end

end
