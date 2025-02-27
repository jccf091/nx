defmodule Nx.Defn.Expr do
  @doc """
  The expression used by `Nx.Defn.Compiler`.

  `Nx.Defn.Compiler` changes `Nx` default backend from `Nx.BinaryBackend`
  to `Nx.Defn.Expr`. It is a struct with the following fields:

    * `:id` - a unique identifier
    * `:op` - the operation name
    * `:args` - the operation arguments
    * `:context` - the context of the expression.
      The default context is `:root`.

  Convenience functions for traversing expressions can be found
  in `Nx.Defn.Tree`.

  ## Syntax nodes

  Most nodes are created directly via the `Nx` module and
  therefore map directly to `Nx.Tensor` callbacks. However
  the following syntax nodes exist:

    * `parameter(integer)`

    * `scalar(number)`

    * `tensor(tensor)`

    * `metadata(expr, metadata)`

    * `elem(tuple, pos, size)` - created automatically from
      expression that return tuples. Note it may return tuples
      too, which means we have nested tuples

    * `fun(parameters, t, mfa)` - the `mfa` is used only for
      introspection purposes

    * `cond(clauses, otherwise)`

    * `while(initial, condition, body)`

  Custom compilers must handle said nodes accordingly.
  """

  alias Nx.Defn.{Expr, Tree}
  alias Nx.Tensor, as: T

  import Nx.Shared

  @enforce_keys [:id, :op, :args, :context]
  defstruct [:id, :op, :args, :context]

  ## Public API

  @doc """
  Builds an tensor expression from the given tensor.
  """
  def tensor(tensor), do: to_expr(tensor)

  @doc """
  Creates a tensor expression parameter at `pos` based on the given tensor expression.
  """
  def parameter(%T{data: %Expr{context: context}} = tensor, pos) do
    parameter(tensor, context, pos)
  end

  @doc """
  Creates a tensor expression parameter at `pos` based on the given `tensor` and `context`.
  """
  def parameter(tensor, context, pos) when is_integer(pos) and pos >= 0 do
    expr(tensor, context, :parameter, [pos])
  end

  @doc """
  Creates a tensor expression parameter at `pos` with the given `context`, `type`,
  `shape`, and `pos`.
  """
  def parameter(context, type, shape, pos) do
    names = List.duplicate(nil, tuple_size(shape))
    expr(%T{type: type, shape: shape, names: names}, context, :parameter, [pos])
  end

  @doc """
  Creates a tensor expression metadata node wrapping the given tensor expression.
  """
  def metadata(expr, metadata) when is_map(metadata) do
    expr = to_expr(expr)
    expr(expr, expr.data.context, :metadata, [expr, metadata])
  end

  @doc """
  Creates a tensor expression function node with the given context,
  args, body, context and mfa for metadata.

  args must be a list of parameter nodes.
  """
  def fun(context, args, body, {_, _, _} = mfa) do
    case Tree.composite(body, &to_expr/1) do
      %T{} = tensor ->
        expr(tensor, context, :fun, [args, tensor, mfa])

      tuple when is_tuple(tuple) ->
        expr(tuple_out(tuple_size(tuple)), context, :fun, [args, tuple, mfa])
    end
  end

  @doc """
  Creates a tensor expression function node with the given context,
  the anonymous function and args.

  args must be a list of parameter nodes.
  """
  def fun(context, fun, args) when is_function(fun, length(args)) do
    {:module, mod} = Function.info(fun, :module)
    {:name, name} = Function.info(fun, :name)
    {:arity, arity} = Function.info(fun, :arity)
    fun(context, args, apply(fun, args), {mod, name, arity})
  end

  @doc """
  Creates a tuple given by the shapes in `tuple` that point to `expr`.
  """
  def tuple(tuple, %T{type: {:tuple, size}, data: %{context: context}} = expr)
      when is_tuple(tuple) and tuple_size(tuple) == size do
    tuple
    |> Tuple.to_list()
    |> Enum.with_index(fn tensor, i ->
      fun = &expr(&1, context, :elem, [expr, i, size])
      composite(tensor, fun)
    end)
    |> List.to_tuple()
  end

  defp tuple_out(size) do
    %T{shape: {}, names: [], type: {:tuple, size}}
  end

  @doc """
  Creates a `cond` tensor expression.
  """
  def cond(clauses, last) do
    {preds, exprs} = Enum.unzip(clauses)
    {preds, context} = to_exprs(preds)
    {out, [last | exprs]} = to_clauses(last, exprs, &cond_clause/2)
    clauses = Enum.zip(preds, exprs)
    composite(out, &expr(&1, context, :cond, [clauses, last]))
  end

  defp cond_clause(type = last, exprs) do
    %{shape: shape, names: names} = last = to_expr(last)

    {exprs, {type, shape, names}} =
      Enum.map_reduce(exprs, {type, shape, names}, fn expr, {type, shape, names} ->
        type = binary_type(type, expr)
        expr = to_expr(expr)
        {shape, names} = Nx.Shape.binary_broadcast(shape, names, expr.shape, expr.names)
        {expr, {type, shape, names}}
      end)

    for expr <- [last | exprs] do
      expr
      |> Nx.as_type(type)
      |> Nx.broadcast(shape, names: names)
    end
  end

  ## Nx.Defn AST callbacks

  @doc false
  def id(), do: make_ref()

  @doc false
  def cond(file, clauses, last) do
    clauses =
      for {meta, {pred, expr}} <- clauses do
        pred = to_expr(pred)

        if not match?(%T{shape: {}}, pred) do
          raise CompileError,
            line: meta[:line],
            file: file,
            description: "condition must be a scalar tensor, got: #{inspect(pred)}"
        end

        if not compatible?(last, expr, fn _, _ -> true end) do
          raise CompileError,
            line: meta[:line],
            file: file,
            description:
              "cond/if expects all branches to return tensors, tuples of the same size, or maps with the same keys. " <>
                "Got #{to_type_shape_string(last)} and #{to_type_shape_string(expr)}"
        end

        {pred, expr}
      end

    cond(clauses, last)
  end

  @doc false
  def while(file, line, initial, condition, body) do
    initial = Tree.composite(initial, &to_expr/1)

    {arg, {_counter, context}} =
      Tree.composite(initial, {0, nil}, fn expr, {counter, acc} ->
        {parameter(expr, :while, counter), {counter + 1, merge_context!(expr, acc)}}
      end)

    condition = condition.(arg)

    if not match?(%T{shape: {}}, condition) do
      raise CompileError,
        line: line,
        file: file,
        description: "condition must be a scalar tensor, got: #{inspect(condition)}"
    end

    body = arg |> body.() |> Tree.composite(&to_expr/1)

    if not compatible?(initial, body, &Nx.compatible?/2) do
      raise CompileError,
        line: line,
        file: file,
        description:
          "the do-block in while must return the shape, type, and names as the initial arguments. " <>
            "Got body #{to_type_shape_string(body)} and initial #{to_type_shape_string(initial)}"
    end

    {out, [initial, arg, body]} = to_clauses(initial, [arg, body], &[&1 | &2])
    composite(out, &expr(&1, context, :while, [initial, arg, condition, body]))
  end

  # Convert to a composite type recursively - if there is any composite type at all.
  # Notice maps only exist in Elixir, they are converted to tuples in the GPUs.

  defp composite(%T{} = tensor, fun), do: fun.(tensor)

  defp composite(tuple, fun) when is_tuple(tuple) do
    expr = fun.(tuple_out(tuple_size(tuple)))
    tuple(tuple, expr)
  end

  defp composite(map, fun) when is_map(map) do
    size = map_size(map)
    %{data: %{context: context}} = expr = fun.(tuple_out(size))

    map
    |> Enum.sort()
    |> Enum.with_index(fn {k, v}, i ->
      fun = &expr(&1, context, :elem, [expr, i, size])
      {k, composite(v, fun)}
    end)
    |> Map.new()
  end

  defp composite(other, fun), do: fun.(to_expr(other))

  ## Nx.Backend Callbacks

  @behaviour Nx.Backend

  @impl true
  def from_binary(binary, type, _options) do
    tensor(Nx.BinaryBackend.from_binary(binary, type, []))
  end

  @impl true
  def eye(out, _backend_options) do
    expr(out, nil, :eye, [])
  end

  @impl true
  def iota(out, axis, _backend_options) do
    expr(out, nil, :iota, [axis])
  end

  @impl true
  def random_uniform(out, min, max, _backend_options) do
    {[min, max], context} = to_exprs([min, max])
    expr(out, context, :random_uniform, [min, max])
  end

  @impl true
  def random_normal(out, mu, sigma, _backend_options) do
    {[mu, sigma], context} = to_exprs([mu, sigma])
    expr(out, context, :random_normal, [mu, sigma])
  end

  unary_ops =
    [:exp, :expm1, :log, :log1p, :logistic, :cos, :sin, :tan, :cosh, :sinh, :tanh] ++
      [:acosh, :asinh, :atanh, :sqrt, :rsqrt, :cbrt, :negate, :sign, :abs, :bitwise_not] ++
      [:population_count, :count_leading_zeros, :floor, :ceil, :round] ++
      [:erf, :erfc, :erf_inv, :acos, :asin, :atan, :bitcast]

  for op <- unary_ops do
    @impl true
    def unquote(op)(out, tensor) do
      tensor = to_expr(tensor)
      expr(out, tensor.data.context, unquote(op), [tensor])
    end
  end

  @impl true
  def add(out, t1, t2) do
    {[t1, t2], context} = to_exprs([t1, t2])
    s1 = maybe_scalar(t1)
    s2 = maybe_scalar(t2)

    cond do
      s1 == 0 ->
        ensure_compatible(t2, out)

      s2 == 0 ->
        ensure_compatible(t1, out)

      s1 && s2 ->
        to_scalar(s1 + s2, out)

      s2 ->
        commute(out, context, :add, &+/2, s2, t2, t1)

      true ->
        case t2 do
          %T{data: %Expr{op: :subtract, args: [%T{data: %Expr{op: :scalar, args: [scalar]}}, t2]}}
          when scalar == 0 ->
            binary_expr(out, context, :subtract, t1, t2)

          %T{} ->
            commute(out, context, :add, &+/2, s1, t1, t2)
        end
    end
  end

  @impl true
  def subtract(out, t1, t2) do
    {[t1, t2], context} = to_exprs([t1, t2])
    s1 = maybe_scalar(t1)
    s2 = maybe_scalar(t2)

    cond do
      s2 == 0 -> ensure_compatible(t1, out)
      s1 && s2 -> to_scalar(s1 - s2, out)
      true -> binary_expr(out, context, :subtract, t1, t2)
    end
  end

  @impl true
  def multiply(out, t1, t2) do
    {[t1, t2], context} = to_exprs([t1, t2])
    s1 = maybe_scalar(t1)
    s2 = maybe_scalar(t2)

    cond do
      s1 == 1 ->
        ensure_compatible(t2, out)

      s2 == 1 ->
        ensure_compatible(t1, out)

      s1 && s2 ->
        to_scalar(s1 * s2, out)

      s2 ->
        commute(out, context, :multiply, &*/2, s2, t2, t1)

      true ->
        case t2 do
          %T{data: %Expr{op: :divide, args: [%T{data: %Expr{op: :scalar, args: [scalar]}}, t2]}}
          when scalar == 1 ->
            binary_expr(out, context, :divide, t1, t2)

          %T{} ->
            commute(out, context, :multiply, &*/2, s1, t1, t2)
        end
    end
  end

  @impl true
  def divide(out, t1, t2) do
    {[t1, t2], context} = to_exprs([t1, t2])
    s1 = maybe_scalar(t1)
    s2 = maybe_scalar(t2)

    cond do
      s2 == 1 -> ensure_compatible(t1, out)
      s1 && s2 -> to_scalar(s1 / s2, out)
      true -> binary_expr(out, context, :divide, t1, t2)
    end
  end

  @impl true
  def power(out, t1, t2) do
    {[t1, t2], context} = to_exprs([t1, t2])
    s2 = maybe_scalar(t2)

    cond do
      s2 == 1 -> ensure_compatible(t1, out)
      true -> binary_expr(out, context, :power, t1, t2)
    end
  end

  binary_ops =
    [:remainder, :atan2, :max, :min, :quotient] ++
      [:bitwise_and, :bitwise_or, :bitwise_xor, :left_shift, :right_shift] ++
      [:equal, :not_equal, :greater, :less, :less_equal, :greater_equal] ++
      [:logical_and, :logical_or, :logical_xor] ++
      [:outer]

  for op <- binary_ops do
    @impl true
    def unquote(op)(out, t1, t2) do
      {[t1, t2], context} = to_exprs([t1, t2])
      binary_expr(out, context, unquote(op), t1, t2)
    end
  end

  aggregate_ops = [:all?, :any?, :argmax, :argmin, :sum, :product, :reduce_min, :reduce_max]

  for op <- aggregate_ops do
    @impl true
    def unquote(op)(out, tensor, opts) do
      tensor = to_expr(tensor)
      expr(out, tensor.data.context, unquote(op), [tensor, opts])
    end
  end

  window_aggregate_ops = [:window_sum, :window_product, :window_max, :window_min]

  for op <- window_aggregate_ops do
    @impl true
    def unquote(op)(out, tensor, window_dimensions, opts) do
      tensor = to_expr(tensor)
      expr(out, tensor.data.context, unquote(op), [tensor, window_dimensions, opts])
    end
  end

  @impl true
  def reduce(%{type: type} = out, tensor, acc, opts, fun) do
    args = [parameter(:reduce, type, {}, 0), parameter(:reduce, type, {}, 1)]
    {[tensor, acc], context} = to_exprs([tensor, acc])
    fun = fun(context, fun, args)

    if fun.shape != {} do
      raise "reduce function must return a scalar tensor, got: #{inspect(fun.shape)}"
    end

    expr(out, context, :reduce, [tensor, acc, opts, fun])
  end

  @impl true
  def reduce_window(
        %{type: type} = out,
        tensor,
        acc,
        window_dims,
        opts,
        fun
      ) do
    args = [parameter(:reduce_window, type, {}, 0), parameter(:reduce_window, type, {}, 1)]
    {[tensor, acc], context} = to_exprs([tensor, acc])
    fun = fun(context, fun, args)

    if fun.shape != {} do
      raise "reduce_window function must return a scalar tensor, got: #{inspect(fun.shape)}"
    end

    expr(out, context, :reduce_window, [tensor, acc, window_dims, opts, fun])
  end

  @impl true
  def map(%{type: type} = out, tensor, fun) do
    args = [parameter(:map, type, {}, 0)]
    %{data: %{context: context}} = tensor = to_expr(tensor)
    expr(out, context, :map, [tensor, fun(context, fun, args)])
  end

  @impl true
  def scatter_window_max(out, tensor, source, window_dims, opts, init_value) do
    {[tensor, source, init_value], context} = to_exprs([tensor, source, init_value])

    expr(out, context, :scatter_window_max, [
      tensor,
      source,
      window_dims,
      opts,
      init_value
    ])
  end

  @impl true
  def scatter_window_min(out, tensor, source, window_dims, opts, init_value) do
    {[tensor, source, init_value], context} = to_exprs([tensor, source, init_value])

    expr(out, context, :scatter_window_min, [
      tensor,
      source,
      window_dims,
      opts,
      init_value
    ])
  end

  @impl true
  def reshape(out, tensor, shape) do
    tensor = to_expr(tensor)
    expr(out, tensor.data.context, :reshape, [tensor, shape])
  end

  @impl true
  def squeeze(out, tensor, axes) do
    tensor = to_expr(tensor)

    # If we are in a sequence of squeezes, we collapse them.
    # This helps us fuse the access syntax.
    with %T{data: %Expr{op: :squeeze, args: [tensor, inner_axes]}} <- tensor do
      axes = merge_squeeze(Enum.sort(inner_axes), Enum.sort(axes), 0)
      expr(out, tensor.data.context, :squeeze, [tensor, axes])
    else
      _ -> expr(out, tensor.data.context, :squeeze, [tensor, axes])
    end
  end

  defp merge_squeeze([inner_axis | inner_axes], [axis | axes], extra)
       when inner_axis <= axis + extra,
       do: [inner_axis | merge_squeeze(inner_axes, [axis | axes], extra + 1)]

  defp merge_squeeze(inner_axes, [axis | axes], extra),
    do: [axis + extra | merge_squeeze(inner_axes, axes, extra)]

  defp merge_squeeze([], [], _extra),
    do: []

  @impl true
  def transpose(out, tensor, axes) do
    tensor = to_expr(tensor)
    expr(out, tensor.data.context, :transpose, [tensor, axes])
  end

  @impl true
  def as_type(out, tensor) do
    tensor = to_expr(tensor)

    if s = maybe_scalar(tensor) do
      to_scalar(s, out)
    else
      expr(out, tensor.data.context, :as_type, [tensor])
    end
  end

  @impl true
  def broadcast(out, tensor, shape, axes) do
    tensor = to_expr(tensor)

    with %T{data: %Expr{op: :broadcast, args: [inner_tensor, inner_shape, inner_axes]}} <- tensor,
         true <-
           (contiguous?(inner_axes, 0) and contiguous?(axes, 0)) or
             (contiguous_last?(inner_axes, inner_shape, inner_tensor) and
                contiguous_last?(axes, shape, tensor)) do
      expr(out, tensor.data.context, :broadcast, [inner_tensor, shape, inner_axes])
    else
      _ ->
        if scalar = maybe_scalar(tensor) do
          to_scalar(scalar, out)
        else
          expr(out, tensor.data.context, :broadcast, [tensor, shape, axes])
        end
    end
  end

  defp contiguous_last?(axes, out_shape, in_shape),
    do: contiguous?(axes, Nx.rank(out_shape) - Nx.rank(in_shape))

  defp contiguous?([], _), do: true
  defp contiguous?([i | rest], i), do: contiguous?(rest, i + 1)
  defp contiguous?(_, _), do: false

  @impl true
  def dot(out, t1, c1, b1, t2, c2, b2) do
    {[t1, t2], context} = to_exprs([t1, t2])
    expr(out, context, :dot, [t1, c1, b1, t2, c2, b2])
  end

  @impl true
  def conv(out, inp, kernel, opts) do
    {[inp, kernel], context} = to_exprs([inp, kernel])
    expr(out, context, :conv, [inp, kernel, opts])
  end

  @impl true
  def pad(out, expr, value, config) do
    {[expr, value], context} = to_exprs([expr, value])
    expr(out, context, :pad, [expr, value, config])
  end

  @impl true
  def select(out, pred, on_true, on_false) do
    {[pred, on_true, on_false], context} = to_exprs([pred, on_true, on_false])
    expr(out, context, :select, [pred, on_true, on_false])
  end

  @impl true
  def clip(out, operand, min, max) do
    {[operand, min, max], context} = to_exprs([operand, min, max])
    expr(out, context, :clip, [operand, min, max])
  end

  @impl true
  def slice(out, tensor, start, lengths, strides) do
    all_static? = Enum.all?(start, &is_integer/1)

    {[tensor | start], context} =
      if all_static? do
        tensor = to_expr(tensor)
        {[tensor | start], tensor.data.context}
      else
        to_exprs([tensor | start])
      end

    # If we are in a sequence of slices, it is the access syntax,
    # so we compact them into a single slice.
    with true <- ones_stride?(strides),
         {slice, axes} <- maybe_squeeze(tensor),
         %T{data: %Expr{op: :slice, args: [tensor, inner_start, inner_lengths, strides]}} <-
           slice,
         true <- ones_stride?(strides) do
      {start, lengths} =
        0
        |> merge_slice(axes, inner_start, start, inner_lengths, lengths)
        |> Enum.unzip()

      tensor
      |> Nx.slice(start, lengths)
      |> Nx.squeeze(axes: axes)
    else
      _ ->
        expr(out, context, :slice, [tensor, start, lengths, strides])
    end
  end

  defp ones_stride?(strides), do: Enum.all?(strides, &(&1 == 1))

  defp maybe_squeeze(%T{data: %Expr{op: :squeeze, args: [slice, axes]}}), do: {slice, axes}
  defp maybe_squeeze(slice), do: {slice, []}

  defp merge_slice(_axis, _axes, [], [], [], []), do: []

  defp merge_slice(axis, axes, [is | inner_start], start, [il | inner_lengths], lengths) do
    # This is one of the erased axes, so we need to get coordinates from inner
    if axis in axes do
      [{is, il} | merge_slice(axis + 1, axes, inner_start, start, inner_lengths, lengths)]
    else
      [s | start] = start
      [l | lengths] = lengths

      [
        {Nx.Defn.Kernel.+(is, s), l}
        | merge_slice(axis + 1, axes, inner_start, start, inner_lengths, lengths)
      ]
    end
  end

  @impl true
  def put_slice(out, tensor, slice, start) do
    {[tensor, slice | start], context} = to_exprs([tensor, slice | start])

    expr(out, context, :put_slice, [tensor, slice, start])
  end

  @impl true
  def reverse(out, tensor, axes) do
    tensor = to_expr(tensor)
    expr(out, tensor.data.context, :reverse, [tensor, axes])
  end

  @impl true
  def concatenate(out, tensors, axis) do
    {tensors, context} = to_exprs(tensors)
    expr(out, context, :concatenate, [tensors, axis])
  end

  @impl true
  def cholesky(out, tensor) do
    tensor = to_expr(tensor)
    expr(out, tensor.data.context, :cholesky, [tensor])
  end

  @impl true
  def triangular_solve(out, a, b, opts) do
    {[a, b], context} = to_exprs([a, b])
    expr(out, context, :triangular_solve, [a, b, opts])
  end

  @impl true
  def lu({p, l, u}, tensor, opts) do
    tensor = to_expr(tensor)
    context = tensor.data.context
    out = %T{names: [], shape: {}, type: {:tuple, 3}}
    tuple({p, l, u}, expr(out, context, :lu, [{p, l, u}, tensor, opts]))
  end

  @impl true
  def qr({q, r}, tensor, opts) do
    tensor = to_expr(tensor)
    context = tensor.data.context
    out = %T{names: [], shape: {}, type: {:tuple, 2}}
    tuple({q, r}, expr(out, context, :qr, [{q, r}, tensor, opts]))
  end

  @impl true
  def svd({u, s, vt}, tensor, opts) do
    tensor = to_expr(tensor)
    context = tensor.data.context
    out = %T{names: [], shape: {}, type: {:tuple, 3}}
    tuple({u, s, vt}, expr(out, context, :svd, [{u, s, vt}, tensor, opts]))
  end

  @impl true
  def sort(out, tensor, opts) do
    %{data: %{context: context}} = tensor = to_expr(tensor)
    expr(out, context, :sort, [tensor, opts])
  end

  @impl true
  def argsort(out, tensor, opts) do
    %{data: %{context: context}} = tensor = to_expr(tensor)
    expr(out, context, :argsort, [tensor, opts])
  end

  ## Undefined

  @impl true
  def backend_transfer(out, __MODULE__, _), do: out

  ops =
    [backend_copy: 3, backend_deallocate: 1, backend_transfer: 3] ++
      [to_binary: 2, to_batched_list: 3, scalar: 3]

  for {op, arity} <- ops do
    args = Macro.generate_arguments(arity, __MODULE__)

    @impl true
    def unquote(op)(unquote_splicing(args)) do
      raise ArgumentError, """
      cannot invoke #{unquote(op)}/#{unquote(arity)} on Nx.Defn.Expr.

      This typically means you are invoking an unsupported Nx function
      by code inside `defn` or JIT/AOT compiled code
      """
    end
  end

  ## Helpers

  defp expr(tensor, context, op, args) do
    %{tensor | data: %Expr{id: id(), op: op, args: args, context: context}}
  end

  defp to_expr(%T{data: %Expr{}} = t),
    do: t

  defp to_expr(%T{data: %Nx.BinaryBackend{}, shape: {}} = t),
    do: to_scalar(Nx.to_scalar(t), t)

  defp to_expr(%T{} = t),
    do: expr(t, nil, :tensor, [t])

  defp to_expr(number) when is_number(number),
    do: to_scalar(number, %T{shape: {}, names: [], type: Nx.Type.infer(number)})

  defp to_expr(other) do
    raise ArgumentError,
          "unable to build tensor expression, expected a tensor or a number, " <>
            "got: #{inspect(other)}"
  end

  defp to_exprs(list) do
    Enum.map_reduce(list, nil, fn tensor, acc ->
      expr = to_expr(tensor)
      {expr, merge_context!(expr, acc)}
    end)
  end

  defp merge_context!(%{data: %{context: context}}, acc) do
    if context != acc and context != nil and acc != nil do
      raise """
      cannot build defn because expressions come from different contexts: \
      #{inspect(context)} and #{inspect(acc)}.

      This typically happens on "while" and inside anonymous functions, which \
      do not behave like closures inside defn. For example, this is not valid:

          defn example(t, amplifier) do
            Nx.reduce(t, 0, fn val, acc ->
              val * amplifier + acc
            end)
          end

      In the example above, "amplifier" is a variable defined outside of \
      the anonymous function, which is not allowed in defn.
      """
    end

    context || acc
  end

  ## Compatibility checking

  defp compatible?(left, right, fun)
       when (is_number(left) or is_struct(left, T)) and (is_number(right) or is_struct(right, T)),
       do: fun.(left, right)

  defp compatible?(left, right, fun) when tuple_size(left) == tuple_size(right),
    do: compatible_tuple?(left, right, tuple_size(left), fun)

  defp compatible?(left, right, fun) when map_size(left) == map_size(right),
    do: compatible_map?(left, right, Map.keys(left), fun)

  defp compatible?(_, _, _),
    do: false

  defp compatible_map?(_left, _right, [], _fun),
    do: true

  defp compatible_map?(left, right, [key | keys], fun),
    do: compatible?(left[key], right[key], fun) and compatible_map?(left, right, keys, fun)

  defp compatible_tuple?(_left, _right, 0, _fun),
    do: true

  defp compatible_tuple?(left, right, pos, fun) do
    compatible?(:erlang.element(pos, left), :erlang.element(pos, right), fun) and
      compatible_tuple?(left, right, pos - 1, fun)
  end

  defp to_type_shape_string(%{type: type, shape: shape, names: names}) do
    Nx.Type.to_string(type) <> Nx.Shape.to_string(shape, names)
  end

  defp to_type_shape_string(tuple) when is_tuple(tuple) do
    list = Tuple.to_list(tuple)
    IO.iodata_to_binary(["{", Enum.map_intersperse(list, ", ", &to_type_shape_string/1), "}"])
  end

  defp to_type_shape_string(map) when is_map(map) do
    pairs =
      Enum.map_intersperse(map, ", ", fn {k, v} ->
        [inspect(k), " => ", to_type_shape_string(v)]
      end)

    IO.iodata_to_binary(["%{", pairs, "}"])
  end

  ## Clause handling

  defp to_clauses(last, exprs, fun) when is_map(last) and not is_struct(last) do
    keys = Enum.sort(Map.keys(last))

    {list_of_last, list_of_lists} =
      keys
      |> Enum.map(fn key ->
        exprs = Enum.map(exprs, & &1[key])
        to_clauses(last[key], exprs, fun)
      end)
      |> Enum.unzip()

    {Map.new(Enum.zip(keys, list_of_last)), unzip_cons([last | exprs], list_of_lists)}
  end

  defp to_clauses(last, exprs, fun) when is_tuple(last) do
    {list_of_last, list_of_lists} =
      last
      |> Tuple.to_list()
      |> Enum.with_index(fn last, index ->
        exprs = Enum.map(exprs, &elem(&1, index))
        to_clauses(last, exprs, fun)
      end)
      |> Enum.unzip()

    {List.to_tuple(list_of_last), unzip_cons([last | exprs], list_of_lists)}
  end

  defp to_clauses(last, exprs, fun) do
    [last | exprs] = fun.(last, exprs)
    {last, [last | exprs]}
  end

  defp unzip_cons(last_and_exprs, list_of_lists) do
    {last_and_exprs, _} =
      Enum.map_reduce(last_and_exprs, list_of_lists, fn _, list_of_lists ->
        unzip_cons(list_of_lists, [], [])
      end)

    last_and_exprs
  end

  defp unzip_cons([[head | tail] | rest], heads, tails),
    do: unzip_cons(rest, [head | heads], [tail | tails])

  defp unzip_cons([], heads, tails),
    do: {heads |> Enum.reverse() |> List.to_tuple(), Enum.reverse(tails)}

  ## Scalar helpers and related optimizations

  defp maybe_scalar(expr) do
    case expr do
      %T{data: %Expr{op: :scalar, args: [number]}} -> number
      _ -> nil
    end
  end

  # For scalars, make the ID be deterministic to improve cache reuse
  defp to_scalar(number, %{type: type, shape: shape} = tensor) when is_number(number) do
    id = {number, type, shape}
    number = if is_integer(number) and Nx.Type.float?(type), do: 1.0 * number, else: number
    %{tensor | data: %Expr{id: id, op: :scalar, args: [number], context: nil}}
  end

  defp ensure_compatible(t, out) do
    t |> Nx.as_type(out.type) |> Nx.broadcast(out.shape)
  end

  # Rewrite commutative operations so the scalar always come on the left
  defp commute(out, context, op, fun, s1, t1, t2) do
    {a1, a2} =
      case t2 do
        %T{data: %Expr{op: ^op, args: [%T{data: %Expr{op: :scalar, args: [s2]}}, t3]}} ->
          nullary_out = %{out | shape: {}, names: []}

          if s1 do
            {to_scalar(fun.(s1, s2), nullary_out), t3 |> Nx.broadcast(out.shape)}
          else
            {to_scalar(s2, nullary_out), apply(Nx, op, [t1, t3]) |> Nx.broadcast(out.shape)}
          end

        %T{} ->
          case t1 do
            %T{data: %Expr{op: ^op, args: [%T{data: %Expr{op: :scalar, args: [s1]}}, t3]}} ->
              nullary_out = %{out | shape: {}, names: []}
              {to_scalar(s1, nullary_out), apply(Nx, op, [t2, t3]) |> Nx.broadcast(out.shape)}

            %T{} ->
              {t1, t2}
          end
      end

    binary_expr(out, context, op, a1, a2)
  end

  defp binary_expr(tensor, context, op, arg1, arg2) do
    {arg1, arg2} =
      case {arg1, arg2} do
        {%T{data: %Expr{op: :scalar, args: [s]}, shape: shape}, %T{shape: shape}} ->
          {to_scalar(s, %{arg1 | shape: {}, names: []}), arg2}

        {%T{shape: shape}, %T{data: %Expr{op: :scalar, args: [s]}, shape: shape}} ->
          {arg1, to_scalar(s, %{arg2 | shape: {}, names: []})}

        {_, _} ->
          {arg1, arg2}
      end

    expr(tensor, context, op, [arg1, arg2])
  end

  ## Inspect

  import Inspect.Algebra

  @impl true
  def inspect(tensor, opts) do
    {_, acc} = inspect_expr(tensor, {[], [], %{}, %{}})
    {_, {exprs, params, _var_map, _cache}} = Tree.traverse_args(tensor, acc, &inspect_expr/2)

    all = Enum.reverse(params, Enum.reverse(exprs))
    header = concat(line(), color("Nx.Defn.Expr", :map, opts))
    length = Enum.reduce(all, 0, fn {str, _tensor}, acc -> max(byte_size(str), acc) end)

    all
    |> Enum.map(fn {str, tensor} ->
      String.pad_trailing(str, length, " ") <> "  " <> to_type_shape(tensor)
    end)
    |> Enum.uniq()
    |> Enum.reduce(header, &concat(&2, concat(line(), &1)))
  end

  # Scalars and funs are shown as is
  defp inspect_expr(%T{data: %Expr{op: :scalar}} = t, acc), do: {t, acc}
  defp inspect_expr(%T{data: %Expr{op: :fun}} = t, acc), do: {t, acc}

  defp inspect_expr(%T{data: %Expr{id: id}} = t, {exprs, params, var_map, cache} = acc) do
    case cache do
      %{^id => _} -> {t, acc}
      %{} -> cached_inspect_expr(t, {exprs, params, var_map, Map.put(cache, id, true)})
    end
  end

  defp cached_inspect_expr(%T{data: %Expr{op: op, id: id}} = t, {exprs, params, var_map, cache})
       when op in [:tensor, :parameter] do
    {var, var_map} = var_for_id(var_map, id)
    param = Atom.to_string(op) <> " " <> var
    {t, {exprs, [{param, t} | params], var_map, cache}}
  end

  defp cached_inspect_expr(%T{} = t, acc) do
    %{data: %Expr{id: id, op: op}} = t
    {args, {exprs, params, var_map, cache}} = traverse_args(op, t, acc)
    {var, var_map} = var_for_id(var_map, id)
    args_str = inspect_args(op, args, var_map)
    expr_str = var <> " = " <> Atom.to_string(op) <> " [ " <> args_str <> " ]"
    {t, {[{expr_str, t} | exprs], params, var_map, cache}}
  end

  defp traverse_args(:while, %T{data: %{args: [initial, _, _, _]}}, acc) do
    {initial, acc} = Tree.composite(initial, acc, &inspect_expr/2)
    {[initial], acc}
  end

  defp traverse_args(_op, t, acc) do
    Tree.traverse_args(t, acc, &inspect_expr/2)
  end

  defp inspect_args(:while, [initial], var_map) do
    IO.iodata_to_binary(inspect_arg(initial, var_map))
  end

  defp inspect_args(:cond, [clauses, last], var_map) do
    clauses =
      Enum.map(clauses, fn {pred, expr} ->
        [inspect_arg(pred, var_map), " -> ", inspect_arg(expr, var_map), ", "]
      end)

    IO.iodata_to_binary([clauses, ":otherwise -> ", inspect_arg(last, var_map)])
  end

  defp inspect_args(:metadata, [expr, metadata], var_map) do
    IO.iodata_to_binary([inspect_arg(expr, var_map), ", ", inspect(Map.keys(metadata))])
  end

  defp inspect_args(_op, [tuple | args], var_map) when is_tuple(tuple),
    do: inspect_args(args, var_map)

  defp inspect_args(_op, args, var_map),
    do: inspect_args(args, var_map)

  defp inspect_args(args, var_map),
    do: Enum.map_join(args, ", ", &inspect_arg(&1, var_map))

  defp inspect_arg(arg, var_map) do
    case arg do
      %T{data: %Expr{op: :fun, args: [_, _, {m, f, a}]}} ->
        [?&, Exception.format_mfa(m, f, a)]

      %T{data: %Expr{op: :scalar, args: [number]}} ->
        to_string(number)

      %T{data: %Expr{id: id}} ->
        Map.fetch!(var_map, id)

      _ ->
        cond do
          Keyword.keyword?(arg) and arg != [] ->
            Enum.map_join(arg, ", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)

          is_list(arg) ->
            [?[, inspect_args(arg, var_map), ?]]

          is_tuple(arg) ->
            [?{, inspect_args(Tuple.to_list(arg), var_map), ?}]

          true ->
            inspect(arg)
        end
    end
  end

  defp var_for_id(var_map, id) do
    case var_map do
      %{^id => var} ->
        {var, var_map}

      %{} ->
        var = IO.iodata_to_binary(counter_to_name(map_size(var_map)))
        {var, Map.put(var_map, id, var)}
    end
  end

  defp counter_to_name(counter) when counter >= 26 do
    [counter_to_name(div(counter, 26)) | counter_to_name(rem(counter, 26))]
  end

  defp counter_to_name(counter), do: [Enum.at(?a..?z, counter)]

  defp to_type_shape(%{type: type, shape: shape}) do
    brackets =
      shape
      |> Tuple.to_list()
      |> Enum.map(&[?[, Integer.to_string(&1), ?]])

    IO.iodata_to_binary([Nx.Type.to_string(type) | brackets])
  end
end
