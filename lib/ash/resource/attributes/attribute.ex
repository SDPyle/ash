defmodule Ash.Resource.Attributes.Attribute do
  @moduledoc false

  defstruct [
    :name,
    :type,
    :allow_nil?,
    :generated?,
    :primary_key?,
    :writable?,
    :default,
    :update_default
  ]

  @type t :: %__MODULE__{
          name: atom(),
          type: Ash.Type.t(),
          primary_key?: boolean(),
          default: (() -> term),
          update_default: (() -> term) | (Ash.record() -> term),
          writable?: boolean
        }

  @schema [
    primary_key?: [
      type: :boolean,
      default: false,
      doc:
        "Whether or not the attribute is part of the primary key (one or more fields that uniquely identify a resource)"
    ],
    allow_nil?: [
      type: :boolean,
      default: true,
      doc: "Whether or not the attribute can be set to nil"
    ],
    generated?: [
      type: :boolean,
      default: false,
      doc: "Whether or not the value may be generated by the data layer"
    ],
    writable?: [
      type: :boolean,
      default: true,
      doc: "Whether or not the value can be written to"
    ],
    update_default: [
      type: {:custom, __MODULE__, :validate_default, [:update]},
      doc:
        "A zero argument function, an {mod, fun, args} triple or `{:constant, value}`. If no value is provided for the attribute on update, this value is used."
    ],
    default: [
      type: {:custom, __MODULE__, :validate_default, [:create]},
      doc:
        "A zero argument function, an {mod, fun, args} triple or `{:constant, value}`. If no value is provided for the attribute on create, this value is used."
    ]
  ]

  def validate_default(value, _) when is_function(value, 0), do: {:ok, value}
  def validate_default({:constant, value}, _), do: {:ok, {:constant, value}}

  def validate_default({module, function, args}, _)
      when is_atom(module) and is_atom(function) and is_list(args),
      do: {:ok, {module, function, args}}

  @doc false
  def attribute_schema, do: @schema

  @spec new(Ash.resource(), atom, Ash.Type.t(), Keyword.t()) :: {:ok, t()} | {:error, term}
  def new(_resource, name, type, opts) do
    # Don't call functions on the resource! We don't want it to compile here
    with :ok <- validate_type(type),
         {:ok, opts} <- NimbleOptions.validate(opts, @schema),
         {:default, {:ok, default}} <- {:default, cast_default(type, opts)} do
      {:ok,
       %__MODULE__{
         name: name,
         type: type,
         generated?: opts[:generated?],
         writable?: opts[:writable?],
         allow_nil?: opts[:allow_nil?],
         primary_key?: opts[:primary_key?],
         update_default: opts[:update_default],
         default: default
       }}
    else
      {:error, error} -> {:error, error}
      {:default, _} -> {:error, [{:default, "is not a valid default for type #{inspect(type)}"}]}
    end
  end

  defp validate_type(type) do
    if Ash.Type.ash_type?(type) do
      :ok
    else
      {:error, "#{inspect(type)} is not a valid type"}
    end
  end

  defp cast_default(type, opts) do
    case Keyword.fetch(opts, :default) do
      {:ok, default} when is_function(default, 0) ->
        {:ok, default}

      {:ok, {mod, func, args}} when is_atom(mod) and is_atom(func) ->
        {:ok, {mod, func, args}}

      {:ok, {:constant, default}} ->
        case Ash.Type.cast_input(type, default) do
          {:ok, value} -> {:ok, {:constant, value}}
          :error -> :error
        end

      :error ->
        {:ok, nil}
    end
  end
end
