defmodule Ash.Filter do
  @moduledoc """
  A filter expression in Ash.

  The way we represent filters may be strange, but its important to have it structured,
  as merging and checking filter subsets are used all through ash for things like
  authorization. The `ands` of a filter are not subject to its `ors`. The `not` of a filter
  is also *not* subject to its `ors`.
  For instance, if a filter `A` has two `ands`, `B` and `C` and two `ors`, `D` and `E`, and
  a `not` of F, the expression as can be represented as `(A or D or E) and NOT F and B and C`.

  The filters `attributes` and `relationships`, *are* subject to the `ors` of that filter.

  `<and_statements> AND NOT <not_statement> AND (<one_of_or_statements> OR <attributes + relationships>)

  This probably needs to be refactored into something more representative of its behavior,
  like a series of nested boolean expression structs w/ a reference to the attribute/relationship
  it references. Maybe. This would be similar to Ecto's `BooleanExpr` structs.
  """

  alias Ash.Actions.PrimaryKeyHelpers
  alias Ash.Engine
  alias Ash.Engine.Request
  alias Ash.Filter.{And, Eq, In, Merge, NotEq, NotIn, Or}

  defstruct [
    :api,
    :resource,
    :not,
    ands: [],
    ors: [],
    attributes: %{},
    relationships: %{},
    requests: [],
    path: [],
    errors: [],
    impossible?: false
  ]

  @type t :: %__MODULE__{
          api: Ash.api(),
          resource: Ash.resource(),
          ors: list(%__MODULE__{} | nil),
          not: %__MODULE__{} | nil,
          attributes: Keyword.t(),
          relationships: map(),
          path: list(atom),
          impossible?: boolean,
          errors: list(String.t()),
          requests: list(Request.t())
        }

  @predicates %{
    not_eq: NotEq,
    not_in: NotIn,
    eq: Eq,
    in: In,
    and: And,
    or: Or
  }

  @spec parse(
          Ash.resource(),
          Keyword.t(),
          Ash.api(),
          relationship_path :: list(atom)
        ) :: t()
  @doc """
  Parse a filter from a filter expression

  The only rason to pass `api` would be if you intend to leverage
  any engine requests that would be generated by this filter.
  """
  def parse(resource, filter, api, path \\ [])

  def parse(resource, [], api, _),
    do: %__MODULE__{
      api: api,
      resource: resource
    }

  def parse(_resource, %__MODULE__{} = filter, _, _) do
    filter
  end

  def parse(resource, filter, api, path) do
    parsed_filter = do_parse(filter, %Ash.Filter{resource: resource, api: api, path: path})

    source =
      case path do
        [] -> "filter"
        path -> "related #{Enum.join(path, ".")} filter"
      end

    if path == [] do
      parsed_filter
    else
      query =
        api
        |> Ash.Query.new(resource)
        |> Ash.Query.filter(parsed_filter)

      request =
        Request.new(
          resource: resource,
          api: api,
          query: query,
          path: [:filter, path],
          skip_unless_authorize?: true,
          data:
            Request.resolve(
              [[:filter, path, :query]],
              fn %{filter: %{^path => %{query: query}}} ->
                data_layer_query = Ash.DataLayer.resource_to_query(resource)

                case Ash.DataLayer.filter(data_layer_query, query.filter, resource) do
                  {:ok, filtered_query} ->
                    Ash.DataLayer.run_query(filtered_query, resource)

                  {:error, error} ->
                    {:error, error}
                end
              end
            ),
          action: Ash.primary_action!(resource, :read),
          relationship: path,
          name: source
        )

      add_request(
        parsed_filter,
        request
      )
    end
  end

  def optional_paths(filter) do
    filter
    |> do_optional_paths()
    |> Enum.uniq()
  end

  @doc """
  Returns true if the second argument is a strict subset (always returns the same or less data) of the first
  """
  def strict_subset_of(nil, _), do: true

  def strict_subset_of(_, nil), do: false

  def strict_subset_of(%{resource: resource}, %{resource: other_resource})
      when resource != other_resource,
      do: false

  def strict_subset_of(filter, candidate) do
    if empty_filter?(filter) do
      true
    else
      if empty_filter?(candidate) do
        false
      else
        {filter, candidate} = cosimplify(filter, candidate)

        Ash.SatSolver.strict_filter_subset(filter, candidate)
      end
    end
  end

  def strict_subset_of?(filter, candidate) do
    strict_subset_of(filter, candidate) == true
  end

  def primary_key_filter?(nil), do: false

  def primary_key_filter?(filter) do
    cleared_pkey_filter =
      filter.resource
      |> Ash.primary_key()
      |> Enum.map(fn key -> {key, nil} end)

    case cleared_pkey_filter do
      [] ->
        false

      cleared_pkey_filter ->
        parsed_cleared_pkey_filter = parse(filter.resource, cleared_pkey_filter, filter.api)

        cleared_candidate_filter = clear_equality_values(filter)

        strict_subset_of?(parsed_cleared_pkey_filter, cleared_candidate_filter)
    end
  end

  def get_pkeys(%{query: nil, resource: resource}, api, %_{} = item) do
    pkey_filter =
      item
      |> Map.take(Ash.primary_key(resource))
      |> Map.to_list()

    api
    |> Ash.Query.new(resource)
    |> Ash.Query.filter(pkey_filter)
  end

  def get_pkeys(%{query: query}, _, %resource{} = item) do
    pkey_filter =
      item
      |> Map.take(Ash.primary_key(resource))
      |> Map.to_list()

    Ash.Query.filter(query, pkey_filter)
  end

  def cosimplify(left, right) do
    {new_left, new_right} = simplify_lists(left, right)

    express_mutual_exclusion(new_left, new_right)
  end

  defp simplify_lists(left, right) do
    values = get_all_values(left, get_all_values(right, %{}))

    substitutions =
      Enum.reduce(values, %{}, fn {key, values}, substitutions ->
        value_substitutions = simplify_list_substitutions(values)

        Map.put(substitutions, key, value_substitutions)
      end)

    {replace_values(left, substitutions), replace_values(right, substitutions)}
  end

  defp simplify_list_substitutions(values) do
    Enum.reduce(values, %{}, fn value, substitutions ->
      case do_simplify_list(value) do
        {:ok, substitution} ->
          Map.put(substitutions, value, substitution)

        :error ->
          substitutions
      end
    end)
  end

  defp do_simplify_list(%In{values: []}), do: :error

  defp do_simplify_list(%In{values: [value]}) do
    {:ok, %Eq{value: value}}
  end

  defp do_simplify_list(%In{values: [value | rest]}) do
    {:ok,
     Enum.reduce(rest, %Eq{value: value}, fn value, other_values ->
       Or.prebuilt_new(%Eq{value: value}, other_values)
     end)}
  end

  defp do_simplify_list(%NotIn{values: []}), do: :error

  defp do_simplify_list(%NotIn{values: [value]}) do
    {:ok, %NotEq{value: value}}
  end

  defp do_simplify_list(%NotIn{values: [value | rest]}) do
    {:ok,
     Enum.reduce(rest, %Eq{value: value}, fn value, other_values ->
       And.prebuilt_new(%NotEq{value: value}, other_values)
     end)}
  end

  defp do_simplify_list(_), do: :error

  defp express_mutual_exclusion(left, right) do
    values = get_all_values(left, get_all_values(right, %{}))

    substitutions =
      Enum.reduce(values, %{}, fn {key, values}, substitutions ->
        value_substitutions = express_mutual_exclusion_substitutions(values)

        Map.put(substitutions, key, value_substitutions)
      end)

    {replace_values(left, substitutions), replace_values(right, substitutions)}
  end

  defp express_mutual_exclusion_substitutions(values) do
    Enum.reduce(values, %{}, fn value, substitutions ->
      case do_express_mutual_exclusion(value, values) do
        {:ok, substitution} ->
          Map.put(substitutions, value, substitution)

        :error ->
          substitutions
      end
    end)
  end

  defp do_express_mutual_exclusion(%Eq{value: value} = eq_filter, values) do
    values
    |> Enum.filter(fn
      %Eq{value: other_value} -> value != other_value
      _ -> false
    end)
    |> case do
      [] ->
        :error

      [%{value: other_value}] ->
        {:ok, And.prebuilt_new(eq_filter, %NotEq{value: other_value})}

      values ->
        {:ok,
         Enum.reduce(values, eq_filter, fn %{value: other_value}, expr ->
           And.prebuilt_new(expr, %NotEq{value: other_value})
         end)}
    end
  end

  defp do_express_mutual_exclusion(_, _), do: :error

  defp get_all_values(filter, state) do
    state =
      filter.attributes
      |> Enum.reduce(state, fn {field, value}, state ->
        state
        |> Map.put_new([filter.path, field], [])
        |> Map.update!([filter.path, field], fn values ->
          value
          |> do_get_values()
          |> Enum.reduce(values, fn value, values ->
            [value | values]
          end)
          |> Enum.uniq()
        end)
      end)

    state =
      Enum.reduce(filter.relationships, state, fn {_, relationship_filter}, new_state ->
        get_all_values(relationship_filter, new_state)
      end)

    state =
      if filter.not do
        get_all_values(filter.not, state)
      else
        state
      end

    state =
      Enum.reduce(filter.ors, state, fn or_filter, new_state ->
        get_all_values(or_filter, new_state)
      end)

    Enum.reduce(filter.ands, state, fn and_filter, new_state ->
      get_all_values(and_filter, new_state)
    end)
  end

  defp do_get_values(%struct{left: left, right: right})
       when struct in [And, Or] do
    do_get_values(left) ++ do_get_values(right)
  end

  defp do_get_values(other), do: [other]

  defp replace_values(filter, substitutions) do
    new_attrs =
      Enum.reduce(filter.attributes, %{}, fn {field, value}, attributes ->
        substitutions = Map.get(substitutions, [filter.path, field]) || %{}

        Map.put(attributes, field, do_replace_value(value, substitutions))
      end)

    new_relationships =
      Enum.reduce(filter.relationships, %{}, fn {relationship, related_filter}, relationships ->
        new_relationship_filter = replace_values(related_filter, substitutions)

        Map.put(relationships, relationship, new_relationship_filter)
      end)

    new_not =
      if filter.not do
        replace_values(filter.not, substitutions)
      else
        filter.not
      end

    new_ors =
      Enum.reduce(filter.ors, [], fn or_filter, ors ->
        new_or = replace_values(or_filter, substitutions)

        [new_or | ors]
      end)

    new_ands =
      Enum.reduce(filter.ands, [], fn and_filter, ands ->
        new_and = replace_values(and_filter, substitutions)

        [new_and | ands]
      end)

    %{
      filter
      | attributes: new_attrs,
        relationships: new_relationships,
        not: new_not,
        ors: Enum.reverse(new_ors),
        ands: Enum.reverse(new_ands)
    }
  end

  defp do_replace_value(%struct{left: left, right: right} = compound, substitutions)
       when struct in [And, Or] do
    %{
      compound
      | left: do_replace_value(left, substitutions),
        right: do_replace_value(right, substitutions)
    }
  end

  defp do_replace_value(value, substitutions) do
    case Map.fetch(substitutions, value) do
      {:ok, new_value} ->
        new_value

      _ ->
        value
    end
  end

  defp clear_equality_values(filter) do
    new_attrs =
      Enum.reduce(filter.attributes, %{}, fn {field, value}, attributes ->
        Map.put(attributes, field, do_clear_equality_value(value))
      end)

    new_relationships =
      Enum.reduce(filter.relationships, %{}, fn {relationship, related_filter}, relationships ->
        new_relationship_filter = clear_equality_values(related_filter)

        Map.put(relationships, relationship, new_relationship_filter)
      end)

    new_not =
      if filter.not do
        clear_equality_values(filter)
      else
        filter.not
      end

    new_ors =
      Enum.reduce(filter.ors, [], fn or_filter, ors ->
        new_or = clear_equality_values(or_filter)

        [new_or | ors]
      end)

    new_ands =
      Enum.reduce(filter.ands, [], fn and_filter, ands ->
        new_and = clear_equality_values(and_filter)

        [new_and | ands]
      end)

    %{
      filter
      | attributes: new_attrs,
        relationships: new_relationships,
        not: new_not,
        ors: Enum.reverse(new_ors),
        ands: Enum.reverse(new_ands)
    }
  end

  defp do_clear_equality_value(%struct{left: left, right: right} = compound)
       when struct in [And, Or] do
    %{
      compound
      | left: do_clear_equality_value(left),
        right: do_clear_equality_value(right)
    }
  end

  defp do_clear_equality_value(%Eq{value: _} = filter), do: %{filter | value: nil}
  defp do_clear_equality_value(%In{values: _}), do: %Eq{value: nil}
  defp do_clear_equality_value(other), do: other

  defp do_optional_paths(%{relationships: relationships, requests: requests, ors: ors})
       when relationships == %{} and ors in [[], nil] do
    Enum.map(requests, fn request ->
      request.path
    end)
  end

  defp do_optional_paths(%{ors: [first | rest]} = filter) do
    do_optional_paths(first) ++ do_optional_paths(%{filter | ors: rest})
  end

  defp do_optional_paths(%{relationships: relationships} = filter) when is_map(relationships) do
    relationship_paths =
      Enum.flat_map(relationships, fn {_, value} ->
        do_optional_paths(value)
      end)

    relationship_paths ++ do_optional_paths(%{filter | relationships: %{}})
  end

  def request_filter_for_fetch(filter, data) do
    filter
    |> optional_paths()
    |> paths_and_data(data)
    |> most_specific_paths()
    |> Enum.reduce(filter, fn {path, %{data: related_data}}, filter ->
      [:filter, relationship_path] = path

      filter
      |> add_records_to_relationship_filter(
        relationship_path,
        List.wrap(related_data)
      )
      |> lift_impossibility()
    end)
  end

  defp most_specific_paths(paths_and_data) do
    Enum.reject(paths_and_data, fn {path, _} ->
      Enum.any?(paths_and_data, &path_is_more_specific?(path, &1))
    end)
  end

  # I don't think this is a possibility
  defp path_is_more_specific?([], []), do: false
  defp path_is_more_specific?(_, []), do: true
  # first element of the search matches first element of candidate
  defp path_is_more_specific?([part | rest], [part | candidate_rest]) do
    path_is_more_specific?(rest, candidate_rest)
  end

  defp path_is_more_specific?(_, _), do: false

  defp paths_and_data(paths, data) do
    Enum.flat_map(paths, fn path ->
      case Engine.fetch_nested_value(data, path) do
        {:ok, related_data} -> [{path, related_data}]
        :error -> []
      end
    end)
  end

  def empty_filter?(filter) do
    filter.attributes == %{} and filter.relationships == %{} and filter.not == nil and
      filter.ors in [[], nil] and filter.ands in [[], nil]
  end

  defp add_records_to_relationship_filter(filter, [], records) do
    case PrimaryKeyHelpers.values_to_primary_key_filters(filter.resource, records) do
      {:error, error} ->
        add_error(filter, error)

      {:ok, []} ->
        if filter.ors in [[], nil] do
          %{filter | impossible?: true}
        else
          filter
        end

      {:ok, [single]} ->
        do_parse(single, filter)

      {:ok, many} ->
        do_parse([or: many], filter)
    end
  end

  defp add_records_to_relationship_filter(filter, [relationship | rest] = path, records) do
    filter
    |> Map.update!(:relationships, fn relationships ->
      case Map.fetch(relationships, relationship) do
        {:ok, related_filter} ->
          Map.put(
            relationships,
            relationship,
            add_records_to_relationship_filter(related_filter, rest, records)
          )

        :error ->
          relationships
      end
    end)
    |> Map.update!(:ors, fn ors ->
      Enum.map(ors, &add_records_to_relationship_filter(&1, path, records))
    end)
  end

  defp lift_impossibility(filter) do
    filter =
      filter
      |> Map.update!(:relationships, fn relationships ->
        Enum.reduce(relationships, relationships, fn {key, filter}, relationships ->
          Map.put(relationships, key, lift_impossibility(filter))
        end)
      end)
      |> Map.update!(:ands, fn ands ->
        Enum.map(ands, &lift_impossibility/1)
      end)
      |> Map.update!(:ors, fn ors ->
        Enum.map(ors, &lift_impossibility/1)
      end)

    with_related_impossibility =
      if Enum.any?(filter.relationships || %{}, fn {_, val} -> Map.get(val, :impossible?) end) do
        Map.put(filter, :impossible?, true)
      else
        filter
      end

    if Enum.any?(with_related_impossibility.ands, &Map.get(&1, :impossible?)) do
      Map.put(with_related_impossibility, :impossible?, true)
    else
      with_related_impossibility
    end
  end

  defp add_not_filter_info(filter) do
    case filter.not do
      nil ->
        filter

      not_filter ->
        filter
        |> add_request(not_filter.requests)
        |> add_error(not_filter.errors)
    end
  end

  def predicate_strict_subset_of?(attribute, %left_struct{} = left, right) do
    left_struct.strict_subset_of?(attribute, left, right)
  end

  def add_to_filter(filter, %__MODULE__{} = addition) do
    %{addition | ands: [filter | addition.ands]}
    |> lift_impossibility()
    |> lift_if_empty()
    |> add_not_filter_info()
  end

  def add_to_filter(filter, additions) do
    parsed = parse(filter.resource, additions, filter.api)

    add_to_filter(filter, parsed)
  end

  defp do_parse(filter_statement, %{resource: resource} = filter) do
    Enum.reduce(filter_statement, filter, fn
      {key, value}, filter ->
        cond do
          key == :__impossible__ && value == true ->
            %{filter | impossible?: true}

          key == :and ->
            add_and_to_filter(filter, value)

          key == :or ->
            add_or_to_filter(filter, value)

          key == :not ->
            add_to_not_filter(filter, value)

          attr = Ash.attribute(resource, key) ->
            add_attribute_filter(filter, attr, value)

          rel = Ash.relationship(resource, key) ->
            add_relationship_filter(filter, rel, value)

          true ->
            add_error(
              filter,
              "Attempted to filter on #{key} which is neither a relationship, nor a field of #{
                inspect(resource)
              }"
            )
        end
    end)
    |> lift_impossibility()
    |> lift_if_empty()
    |> add_not_filter_info()
  end

  defp add_and_to_filter(filter, value) do
    if Keyword.keyword?(value) do
      %{filter | ands: [parse(filter.resource, value, filter.api) | filter.ands]}
    else
      empty_filter = parse(filter.resource, [], filter.api)

      filter_with_ands = %{
        empty_filter
        | ands: Enum.map(value, &parse(filter.resource, &1, filter.api))
      }

      %{filter | ands: [filter_with_ands | filter.ands]}
    end
  end

  defp add_or_to_filter(filter, value) do
    if Keyword.keyword?(value) do
      %{filter | ors: [parse(filter.resource, value, filter.api) | filter.ors]}
    else
      [first_or | rest_ors] = Enum.map(value, &parse(filter.resource, &1, filter.api))

      or_filter =
        filter.resource
        |> parse(first_or, filter.api)
        |> Map.update!(:ors, &Kernel.++(&1, rest_ors))

      %{filter | ands: [or_filter | filter.ands]}
    end
  end

  defp add_to_not_filter(filter, value) do
    Map.update!(filter, :not, fn not_filter ->
      if not_filter do
        add_to_filter(not_filter, value)
      else
        parse(filter.resource, value, filter.api)
      end
    end)
  end

  defp lift_if_empty(%{
         ors: [],
         ands: [and_filter | rest],
         attributes: attrs,
         relationships: rels,
         not: nil,
         errors: errors
       })
       when attrs == %{} and rels == %{} do
    and_filter
    |> Map.update!(:ands, &Kernel.++(&1, rest))
    |> lift_if_empty()
    |> Map.update!(:errors, &Kernel.++(&1, errors))
  end

  defp lift_if_empty(%{
         ands: [],
         ors: [or_filter | rest],
         attributes: attrs,
         relationships: rels,
         not: nil,
         errors: errors
       })
       when attrs == %{} and rels == %{} do
    or_filter
    |> Map.update!(:ors, &Kernel.++(&1, rest))
    |> lift_if_empty()
    |> Map.update!(:errors, &Kernel.++(&1, errors))
  end

  defp lift_if_empty(filter) do
    filter
  end

  defp add_attribute_filter(filter, attr, value) do
    if Keyword.keyword?(value) do
      Enum.reduce(value, filter, fn
        {predicate_name, value}, filter ->
          do_add_attribute_filter(filter, attr, predicate_name, value)
      end)
    else
      add_attribute_filter(filter, attr, eq: value)
    end
  end

  defp do_add_attribute_filter(
         %{attributes: attributes, resource: resource} = filter,
         %{type: attr_type, name: attr_name},
         predicate_name,
         value
       ) do
    case parse_predicate(resource, predicate_name, attr_name, attr_type, value) do
      {:ok, predicate} ->
        new_attributes =
          Map.update(
            attributes,
            attr_name,
            predicate,
            &Merge.merge(&1, predicate)
          )

        %{filter | attributes: new_attributes}

      {:error, error} ->
        add_error(filter, error)
    end
  end

  def parse_predicates(resource, keyword, attr_name, attr_type) do
    Enum.reduce(keyword, {:ok, nil}, fn {predicate_name, value}, {:ok, existing_predicate} ->
      case parse_predicate(resource, predicate_name, attr_name, attr_type, value) do
        {:ok, predicate} when is_nil(existing_predicate) ->
          {:ok, predicate}

        {:ok, predicate} ->
          {:ok, Merge.merge(existing_predicate, predicate)}

        {:error, error} ->
          {:error, error}
      end
    end)
  end

  def count_of_clauses(nil), do: 0

  def count_of_clauses(filter) do
    relationship_clauses =
      filter.relationships
      |> Map.values()
      |> Enum.map(fn related_filter ->
        1 + count_of_clauses(related_filter)
      end)
      |> Enum.sum()

    or_clauses =
      filter.ors
      |> Kernel.||([])
      |> Enum.map(&count_of_clauses/1)
      |> Enum.sum()

    not_clauses = count_of_clauses(filter.not)

    and_clauses =
      filter.ands
      |> Enum.map(&count_of_clauses/1)
      |> Enum.sum()

    Enum.count(filter.attributes) + relationship_clauses + or_clauses + not_clauses + and_clauses
  end

  defp parse_predicate(resource, predicate_name, attr_name, attr_type, value) do
    data_layer = Ash.data_layer(resource)

    data_layer_predicates =
      Map.get(Ash.data_layer_filters(resource), Ash.Type.storage_type(attr_type), [])

    all_predicates =
      Enum.reduce(data_layer_predicates, @predicates, fn {name, module}, all_predicates ->
        Map.put(all_predicates, name, module)
      end)

    with {:predicate_type, {:ok, predicate_type}} <-
           {:predicate_type, Map.fetch(all_predicates, predicate_name)},
         {:type_can?, _, true} <-
           {:type_can?, predicate_name,
            Keyword.has_key?(data_layer_predicates, predicate_name) or
              Ash.Type.supports_filter?(resource, attr_type, predicate_name, data_layer)},
         {:data_layer_can?, _, true} <-
           {:data_layer_can?, predicate_name,
            Ash.data_layer_can?(resource, {:filter, predicate_name})},
         {:predicate, _, {:ok, predicate}} <-
           {:predicate, attr_name, predicate_type.new(resource, attr_name, attr_type, value)} do
      {:ok, predicate}
    else
      {:predicate_type, :error} ->
        {:error, :predicate_type, "No such filter type #{predicate_name}"}

      {:predicate, attr_name, {:error, error}} ->
        {:error, Map.put(error, :field, attr_name)}

      {:type_can?, predicate_name, false} ->
        {:error,
         "Cannot use filter type #{inspect(predicate_name)} on type #{inspect(attr_type)}."}

      {:data_layer_can?, predicate_name, false} ->
        {:error, "data layer not capable of provided filter: #{predicate_name}"}
    end
  end

  defp add_relationship_filter(
         %{relationships: relationships} = filter,
         %{destination: destination, name: name} = relationship,
         value
       ) do
    case parse_relationship_filter(value, relationship) do
      {:ok, provided_filter} ->
        related_filter = parse(destination, provided_filter, filter.api, [name | filter.path])

        new_relationships =
          Map.update(relationships, name, related_filter, &Merge.merge(&1, related_filter))

        filter
        |> Map.put(:relationships, new_relationships)
        |> add_relationship_compatibility_error(relationship)
        |> add_error(related_filter.errors)
        |> add_request(related_filter.requests)

      {:error, error} ->
        add_error(filter, error)
    end
  end

  defp parse_relationship_filter(value, %{destination: destination} = relationship) do
    cond do
      match?(%__MODULE__{}, value) ->
        {:ok, value}

      match?(%^destination{}, value) ->
        PrimaryKeyHelpers.value_to_primary_key_filter(destination, value)

      is_map(value) ->
        {:ok, Map.to_list(value)}

      Keyword.keyword?(value) ->
        {:ok, value}

      is_list(value) ->
        parse_relationship_list_filter(value, relationship)

      true ->
        PrimaryKeyHelpers.value_to_primary_key_filter(destination, value)
    end
  end

  defp parse_relationship_list_filter(value, relationship) do
    Enum.reduce_while(value, {:ok, []}, fn item, items ->
      case parse_relationship_filter(item, relationship) do
        {:ok, item_filter} -> {:cont, {:ok, [item_filter | items]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp add_relationship_compatibility_error(%{resource: resource} = filter, %{
         cardinality: cardinality,
         destination: destination,
         name: name
       }) do
    cond do
      not Ash.data_layer_can?(resource, {:filter_related, cardinality}) ->
        add_error(
          filter,
          "Cannot filter on relationship #{name}: #{inspect(Ash.data_layer(resource))} does not support it."
        )

      not (Ash.data_layer(destination) == Ash.data_layer(resource)) ->
        add_error(
          filter,
          "Cannot filter on related entites unless they share a data layer, for now."
        )

      true ->
        filter
    end
  end

  defp add_request(filter, requests)
       when is_list(requests),
       do: %{filter | requests: filter.requests ++ requests}

  defp add_request(%{requests: requests} = filter, request),
    do: %{filter | requests: [request | requests]}

  defp add_error(%{errors: errors} = filter, errors) when is_list(errors),
    do: %{filter | errors: filter.errors ++ errors}

  defp add_error(%{errors: errors} = filter, error), do: %{filter | errors: [error | errors]}
end

defimpl Inspect, for: Ash.Filter do
  import Inspect.Algebra
  import Ash.Filter.InspectHelpers

  defguardp is_empty(val) when is_nil(val) or val == [] or val == %{}

  def inspect(
        %Ash.Filter{
          not: not_filter,
          ors: ors,
          relationships: relationships,
          attributes: attributes,
          ands: ands
        },
        opts
      )
      when not is_nil(not_filter) and is_empty(ors) and is_empty(relationships) and
             is_empty(attributes) and is_empty(ands) do
    if root?(opts) do
      concat(["#Filter<not ", to_doc(not_filter, make_non_root(opts)), ">"])
    else
      concat(["not ", to_doc(not_filter, make_non_root(opts))])
    end
  end

  def inspect(%Ash.Filter{not: not_filter} = filter, opts) when not is_nil(not_filter) do
    if root?(opts) do
      concat([
        "#Filter<not ",
        to_doc(not_filter, make_non_root(opts)),
        " and ",
        to_doc(%{filter | not: nil}, make_non_root(opts)),
        ">"
      ])
    else
      concat([
        "not ",
        to_doc(not_filter, make_non_root(opts)),
        " and ",
        to_doc(%{filter | not: nil}, make_non_root(opts))
      ])
    end
  end

  def inspect(
        %Ash.Filter{ors: ors, relationships: relationships, attributes: attributes, ands: ands},
        opts
      )
      when is_empty(ors) and is_empty(relationships) and is_empty(attributes) and is_empty(ands) do
    if root?(opts) do
      concat(["#Filter<", to_doc(nil, opts), ">"])
    else
      to_doc(nil, opts)
    end
  end

  def inspect(filter, opts) do
    rels = parse_relationships(filter, opts)
    attrs = parse_attributes(filter, opts)

    and_container =
      case attrs ++ rels do
        [] ->
          empty()

        [and_clause] ->
          and_clause

        and_clauses ->
          Inspect.Algebra.container_doc("(", and_clauses, ")", opts, fn term, _ -> term end,
            break: :flex,
            separator: " and"
          )
      end

    with_or_container =
      case Map.get(filter, :ors) do
        nil ->
          and_container

        [] ->
          and_container

        ors ->
          inspected_ors = Enum.map(ors, fn filter -> to_doc(filter, make_non_root(opts)) end)

          or_container =
            Inspect.Algebra.container_doc(
              "(",
              inspected_ors,
              ")",
              opts,
              fn term, _ -> term end,
              break: :strict,
              separator: " or "
            )

          if Enum.empty?(attrs) && Enum.empty?(rels) do
            or_container
          else
            concat(["(", and_container, " or ", or_container, ")"])
          end
      end

    all_container =
      case filter.ands do
        [] ->
          with_or_container

        ands ->
          docs = [with_or_container | Enum.map(ands, &Inspect.inspect(&1, make_non_root(opts)))]

          Inspect.Algebra.container_doc(
            "(",
            docs,
            ")",
            opts,
            fn term, _ -> term end,
            break: :strict,
            separator: " and "
          )
      end

    if root?(opts) do
      concat(["#Filter<", all_container, ">"])
    else
      all_container
    end
  end

  defp parse_relationships(%Ash.Filter{relationships: relationships}, _opts)
       when relationships == %{},
       do: []

  defp parse_relationships(filter, opts) do
    filter
    |> Map.fetch!(:relationships)
    |> Enum.map(fn {key, value} -> to_doc(value, add_to_path(opts, key)) end)
  end

  defp parse_attributes(%Ash.Filter{attributes: attributes}, _opts) when attributes == %{}, do: []

  defp parse_attributes(filter, opts) do
    filter
    |> Map.fetch!(:attributes)
    |> Enum.map(fn {key, value} -> to_doc(value, put_attr(opts, key)) end)
  end
end
