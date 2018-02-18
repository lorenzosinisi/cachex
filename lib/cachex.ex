defmodule Cachex do
  @moduledoc """
  Cachex provides a straightforward interface for in-memory key/value storage.

  Cachex is an extremely fast, designed for caching but also allowing for more
  general in-memory storage. The main goal of Cachex is achieve a caching
  implementation with a wide array of options, without sacrificing performance.
  Internally, Cachex is backed by ETS, allowing for an easy-to-use interface
  sitting upon extremely well tested tools.

  Cachex comes with support for all of the following (amongst other things):

  - Time-based key expirations
  - Maximum size protection
  - Pre/post execution hooks
  - Statistics gathering
  - Multi-layered caching/key fallbacks
  - Transactions and row locking
  - Asynchronous write operations
  - Syncing to a local filesystem
  - User command invocation

  All features are optional to allow you to tune based on the throughput needed.
  See `start_link/3` for further details about how to configure these options and
  example usage.
  """

  # main supervisor
  use Supervisor

  # add all imports
  import Cachex.Errors
  import Cachex.Spec

  # allow unsafe generation
  use Unsafe.Generator,
    handler: :unwrap_unsafe

  # add some aliases
  alias Cachex.Actions
  alias Cachex.Errors
  alias Cachex.ExecutionError
  alias Cachex.Options
  alias Cachex.Services

  # alias any services
  alias Services.Informant
  alias Services.Overseer

  # import util macros
  require Overseer

  # avoid inspect clashes
  import Kernel, except: [ inspect: 2 ]

  # the cache type
  @type cache :: atom | Spec.cache

  # custom status type
  @type status :: :ok | :error

  # generate unsafe definitions
  @unsafe [
    clear:             [ 1, 2 ],
    count:             [ 1, 2 ],
    decr:           [ 2, 3, 4 ],
    del:               [ 2, 3 ],
    dump:              [ 2, 3 ],
    empty?:            [ 1, 2 ],
    execute:           [ 2, 3 ],
    exists?:           [ 2, 3 ],
    expire:            [ 3, 4 ],
    expire_at:         [ 3, 4 ],
    fetch:          [ 2, 3, 4 ],
    get:               [ 2, 3 ],
    get_and_update:    [ 3, 4 ],
    incr:           [ 2, 3, 4 ],
    inspect:              [ 2 ],
    invoke:            [ 3, 4 ],
    keys:              [ 1, 2 ],
    load:              [ 2, 3 ],
    persist:           [ 2, 3 ],
    purge:             [ 1, 2 ],
    put:               [ 3, 4 ],
    put_many:          [ 2, 3 ],
    refresh:           [ 2, 3 ],
    reset:             [ 1, 2 ],
    set:               [ 3, 4 ],
    set_many:          [ 2, 3 ],
    size:              [ 1, 2 ],
    stats:             [ 1, 2 ],
    stream:            [ 1, 2 ],
    take:              [ 2, 3 ],
    touch:             [ 2, 3 ],
    transaction:       [ 3, 4 ],
    ttl:               [ 2, 3 ],
    update:            [ 3, 4 ]
  ]

  ##############
  # Public API #
  ##############

  @doc """
  Creates a new Cachex cache service tree, linked to the current process.

  This will link the cache to the current process, so if your process dies the
  cache will also die. If you don't want this behaviour, please use `start/3`.

  The first argument should be a unique atom, used as the name of the cache
  service for future calls through to Cachex.

  ## Options

    * `:commands`

      </br>
      This option allows you to attach a set of custom commands to a cache in
      order to provide shorthand execution. A cache command must be constructed
      using the `:command` record provided by `Cachex.Spec`.

      </br>
      A cache command will adhere to these basic rules:

      </br>
      - If you define a `:read` command, the return value of your command will
        be passed through as the result of your call to `invoke/4`.
      - If you define a `:write` command, your command must return a two-element
        Tuple. The first element represents the value being returned from your
        `invoke/4` call, and the second represents the value to write back into
        the cache (as an update). If your command does not fit this, errors will
        happen (intentionally).

      </br>
      Commands are set on a per-cache basis, but can be reused across caches. They're
      set only on cache startup and cannot be modified after the cache tree is created.

          iex> import Cachex.Spec
          ...>
          ...> Cachex.start_link(:my_cache, [
          ...>   commands: [
          ...>     last: command(type:  :read, execute:   &List.last/1),
          ...>     trim: command(type: :write, execute: &String.trim/1)
          ...>   ]
          ...> ])
          { :ok, _pid }

      </br>
      Either a `Keyword` or a `Map` can be provided against the `:commands` option as
      we only use `Enum` to verify them before attaching them internally. Please see
      the `Cachex.Spec.command/1` documentation for further customization options.

      </br>
    * `:expiration`

      </br>
      The expiration option provides the ability to customize record expiration at
      a global cache level. The value provided here must be a valid `:expiration`
      record provided by `Cachex.Spec`.

          iex> import Cachex.Spec
          ...>
          ...> Cachex.start_link(:my_cache, [
          ...>   expiration: expiration(
          ...>     # default record expiration
          ...>     default: :timer.seconds(60),
          ...>
          ...>     # how often cleanup should occur
          ...>     interval: :timer.seconds(30),
          ...>
          ...>     # whether to enable lazy checking
          ...>     lazy: true
          ...>   )
          ...> ])
          { :ok, _pid }

      Please see the `Cachex.Spec.expiration/1` documentation for further customization
      options.

      </br>
    * `:fallback`

      </br>
      The fallback option allows global settings related to the `fetch/4` command
      on a cache. The value provided here can either be a valid `:fallback` record
      provided by `Cachex.Spec`, or a single function (which is turned into a record
      internally).

          iex> import Cachex.Spec
          ...>
          ...> Cachex.start_link(:my_cache, [
          ...>   fallback: fallback(
          ...>     # default func to use with fetch/4
          ...>     default: &String.reverse/1,
          ...>
          ...>     # anything to pass to fallbacks
          ...>     provide: { }
          ...>   )
          ...> ])
          { :ok, _pid }

      The `:default` function provided will be used if `fetch/2` is called, rather
      than explicitly passing one at call time. The `:provide` function contains
      state which can be passed to a fallback function if the arity is 2 rather than
      1.

      </br>
      Please see the documentation for `fetch/4`, and the `Cachex.Spec.fallback/1`
      documentation for further information.

      </br>
    * `:hooks`

      </br>
      The `:hooks` option allow the user to attach a list of notification hooks to
      enable listening on cache actions (either before or after they happen). These
      hooks should be valid `:hook` records provided by `Cachex.Spec`. Example hook
      implementations can be found in `Cachex.Stats` and `Cachex.Policy.LRW`.

          iex> import Cachex.Spec
          ...>
          ...> Cachex.start_link(:my_cache, [
          ...>   hooks: hook(module: MyHook, type: :post)
          ...> ])
          { :ok, _pid }

      Please see the `Cachex.Spec.hook/1` documentation for further customization options.

      </br>
    * `:limit`

      </br>
      A cache limit provides a maximum size to cap the cache keyspace at. This should
      be either a positive integer, or a valid `:limit` record provided by `Cachex.Spec`.
      Internally a provided interger will just be coerced to a `:limit` record with some
      default values set.

          iex> import Cachex.Spec
          ...>
          ...> Cachex.start_link(:my_cache, [
          ...>   limit: 500
          ...> ])
          { :ok, _pid }

      Please see the `Cachex.Spec.limit/1` documentation for further customization options.

      </br>
    * `:stats`

      </br>
      This option can be used to toggle statistics gathering for a cache. This is a
      shorthand option to avoid attaching the `Cachex.Stats` hook manually. Statistics
      gathering has very minor overhead due to being implemented as a hook,

      </br>
      Stats can be retrieve from a running cache by using `Cachex.stats/2`.

          iex> Cachex.start_link(:my_cache, [ stats: true ])

    * `:transactional`

      </br>
      This option will specify whether this cache should have transactions and row
      locking enabled from cache startup. Please note that even if this is false,
      it will be enabled the moment a transaction is executed. It's recommended to
      leave this as default as it will handle most use cases in the most performant
      way possible.

          iex> Cachex.start_link(:my_cache, [ transactions: true ])

  """
  @spec start_link(atom, Keyword.t) :: { atom, pid }
  def start_link(name, options \\ [])
  def start_link(name, _options) when not is_atom(name),
    do: error(:invalid_name)
  def start_link(name, options) do
    with { :ok,  true } <- ensure_started(),
         { :ok,  true } <- ensure_unused(name),
         { :ok, cache } <- setup_env(name, options),
         { :ok,   pid }  = Supervisor.start_link(__MODULE__, cache, [ name: name ]),
         { :ok,  link }  = Informant.link(cache),
                ^link   <- Overseer.update(name, link),
     do: { :ok,   pid }
  end

  @doc """
  Creates a new Cachex cache service tree.

  This will not link the cache to the current process, so if your process dies
  the cache will also die. If you don't want this behaviour, please use the
  provided `start_link/3`.

  This function is otherwise identical to `start_link/3` so please see that
  documentation for further information and configuration.
  """
  @spec start(atom, Keyword.t) :: { atom, pid }
  def start(name, options \\ []) do
    with { :ok, pid } <- start_link(name, options) do
      :erlang.unlink(pid) && { :ok, pid }
    end
  end

  @doc false
  # Basic initialization phase for a cache.
  #
  # This will start all cache services required using the `Cachex.Services`
  # module and attach them under a Supervisor instance backing the cache.
  @spec init(cache :: Spec.cache) :: Supervisor.on_start
  def init(cache() = cache) do
    cache
    |> Services.cache_spec
    |> supervise(strategy: :one_for_one)
  end

  @doc """
  Removes all entries from a cache.

  The returned numeric value will contain the total number of keys removed
  from the cache. This is equivalent to running `size/2` before running
  the internal clear operation.

  ## Examples

      iex> Cachex.put(:my_cache, "key", "value")
      iex> Cachex.get(:my_cache, "key")
      iex> Cachex.size(:my_cache)
      { :ok, 1 }

      iex> Cachex.clear(:my_cache)
      { :ok, 1 }

      iex> Cachex.size(:my_cache)
      { :ok, 0 }

  """
  @spec clear(cache, Keyword.t) :: { status, boolean }
  def clear(cache, options \\ []) when is_list(options) do
    Overseer.enforce(cache) do
      Actions.Clear.execute(cache, options)
    end
  end

  @doc """
  Retrieves the number of unexpired records in a cache.

  Unlike `size/2`, this ignores keys which should have expired. Due
  to this taking potentially expired keys into account, it is far more
  expensive than simply calling `size/2` and should only be used when
  the distinction is completely necessary.

  ## Examples

      iex> Cachex.put(:my_cache, "key1", "value1")
      iex> Cachex.put(:my_cache, "key2", "value2")
      iex> Cachex.put(:my_cache, "key3", "value3")
      iex> Cachex.count(:my_cache)
      { :ok, 3 }

  """
  @spec count(cache, Keyword.t) :: { status, number }
  def count(cache, options \\ []) when is_list(options) do
    Overseer.enforce(cache) do
      Actions.Count.execute(cache, options)
    end
  end

  @doc """
  Decrements an entry in the cache.

  This will overwrite any value that was previously set against the provided key,
  and overwrite any TTLs which were already set.

  ## Options

    * `:initial`

      </br>
      An initial value to set the key to if it does not exist. This will
      take place *before* the decrement call. Defaults to 0.

  ## Examples

      iex> Cachex.put(:my_cache, "my_key", 10)
      iex> Cachex.decr(:my_cache, "my_key")
      { :ok, 9 }

      iex> Cachex.put(:my_cache, "my_new_key", 10)
      iex> Cachex.decr(:my_cache, "my_new_key", 5)
      { :ok, 5 }

      iex> Cachex.decr(:my_cache, "missing_key", 5, initial: 2)
      { :ok, -3 }

  """
  @spec decr(cache, any, integer, Keyword.t) :: { status, integer }
  def decr(cache, key, amount \\ 1, options \\ [])
  when is_integer(amount) and is_list(options) do
    via_opt = via({ :decr, [ key, amount, options ] }, options)
    incr(cache, key, amount * -1, via_opt)
  end

  @doc """
  Removes an entry from a cache.

  This will return `{ :ok, true }` regardless of whether a key has been removed
  or not. The `true` value can be thought of as "is key no longer present?".

  ## Examples

      iex> Cachex.put(:my_cache, "key", "value")
      iex> Cachex.get(:my_cache, "key")
      { :ok, "value" }

      iex> Cachex.del(:my_cache, "key")
      { :ok, true }

      iex> Cachex.get(:my_cache, "key")
      { :ok, nil }

  """
  @spec del(cache, any, Keyword.t) :: { status, boolean }
  def del(cache, key, options \\ []) when is_list(options) do
    Overseer.enforce(cache) do
      Actions.Del.execute(cache, key, options)
    end
  end

  @doc """
  Serializes a cache to a location on a filesystem.

  This operation will write the current state of a cache to a provided
  location on a filesystem. The written state can be used alongside the
  `load/3` command to import back in the future.

  It is the responsibility of the user to ensure that the location is
  able to be written to, not the responsibility of Cachex.

  ## Options

    * `:compression`

      </br>
      Specifies the level of compression to apply when serializing (0-9). This
      will default to level 1 compression, which is appropriate for most dumps.

      </br>
      Using a compression level of 0 will disable compression completely. This
      will result in a faster serialization but at the cost of higher space.

  ## Examples

      iex> Cachex.put(:my_cache, "my_key", 10)
      iex> Cachex.dump(:my_cache, "/tmp/my_default_backup")
      { :ok, true }

      iex> Cachex.dump(:my_cache, "/tmp/my_custom_backup", [ compressed: 0 ])
      { :ok, true }

  """
  @spec dump(cache, binary, Keyword.t) :: { status, any }
  def dump(cache, path, options \\ [])
  when is_binary(path) and is_list(options) do
    Overseer.enforce(cache) do
      Actions.Dump.execute(cache, path, options)
    end
  end

  @doc """
  Determines whether a cache contains any entries.

  This does not take the expiration time of keys into account. As such,
  if there are any unremoved (but expired) entries in the cache, they
  will be included in the returned determination.

  ## Examples

      iex> Cachex.put(:my_cache, "key1", "value1")
      iex> Cachex.empty?(:my_cache)
      { :ok, false }

      iex> Cachex.clear(:my_cache)
      { :ok, 1 }

      iex> Cachex.empty?(:my_cache)
      { :ok, true }

  """
  @spec empty?(cache, Keyword.t) :: { status, boolean }
  def empty?(cache, options \\ []) when is_list(options) do
    Overseer.enforce(cache) do
      Actions.Empty.execute(cache, options)
    end
  end

  @doc """
  Executes multiple functions in the context of a cache.

  This can be used when carrying out several cache operations at once
  to avoid the overhead of cache loading and jumps between processes.

  This does not provide a transactional execution, it simply avoids
  the overhead involved in the initial calls to a cache. For a transactional
  implementation, please see `transaction/3`.

  To take advantage of the cache context, ensure to use the cache
  instance provided when executing cache calls. If this is not done
  you will see zero benefits from using `execute/3`.

  ## Examples

      iex> Cachex.put(:my_cache, "key1", "value1")
      iex> Cachex.put(:my_cache, "key2", "value2")
      iex> Cachex.execute(:my_cache, fn(worker) ->
      ...>   val1 = Cachex.get!(worker, "key1")
      ...>   val2 = Cachex.get!(worker, "key2")
      ...>   [val1, val2]
      ...> end)
      { :ok, [ "value1", "value2" ] }

  """
  @spec execute(cache, function, Keyword.t) :: { status, any }
  def execute(cache, operation, options \\ [])
  when is_function(operation, 1) and is_list(options) do
    Overseer.enforce(cache) do
      operation.(cache)
    end
  end

  @doc """
  Determines whether an entry exists in a cache.

  This will take expiration times into account, meaning that
  expired entries will not be considered to exist.

  ## Examples

      iex> Cachex.put(:my_cache, "key", "value")
      iex> Cachex.exists?(:my_cache, "key")
      { :ok, true }

      iex> Cachex.exists?(:my_cache, "missing_key")
      { :ok, false }

  """
  @spec exists?(cache, any, Keyword.t) :: { status, boolean }
  def exists?(cache, key, options \\ []) when is_list(options) do
    Overseer.enforce(cache) do
      Actions.Exists.execute(cache, key, options)
    end
  end

  @doc """
  Places an expiration time on an entry in a cache.

  The provided expiration must be a integer value representing the
  lifetime of the entry in milliseconds. If the provided value is
  not positive, the entry will be immediately evicted.

  If the entry does not exist, no changes will be made in the cache.

  ## Examples

      iex> Cachex.put(:my_cache, "key", "value")
      iex> Cachex.expire(:my_cache, "key", :timer.seconds(5))
      { :ok, true }

      iex> Cachex.expire(:my_cache, "missing_key", :timer.seconds(5))
      { :ok, false }

  """
  @spec expire(cache, any, number, Keyword.t) :: { status, boolean }
  def expire(cache, key, expiration, options \\ [])
  when (is_nil(expiration) or is_number(expiration)) and is_list(options) do
    Overseer.enforce(cache) do
      Actions.Expire.execute(cache, key, expiration, options)
    end
  end

  @doc """
  Updates an entry in a cache to expire at a given time.

  Unlike `expire/4` this call uses an instant in time, rather than a
  duration. The same semantics apply as calls to `expire/4` in that
  instants which have passed will result in immediate eviction.

  ## Examples

      iex> Cachex.put(:my_cache, "key", "value")
      iex> Cachex.expire_at(:my_cache, "key", 1455728085502)
      { :ok, true }

      iex> Cachex.expire_at(:my_cache, "missing_key", 1455728085502)
      { :ok, false }

  """
  @spec expire_at(cache, binary, number, Keyword.t) :: { status, boolean }
  def expire_at(cache, key, timestamp, options \\ [])
  when is_number(timestamp) and is_list(options) do
    via_opts = via({ :expire_at, [ key, timestamp, options ] }, options)
    expire(cache, key, timestamp - now(), via_opts)
  end

  @doc """
  Fetches an entry from a cache, generating a value on cache miss.

  If the entry requested is found in the cache, this function will
  operate in the same way as `get/3`. If the entry is not contained
  in the cache, the provided fallback function will be executed.

  A fallback function is a function used to lazily generate a value
  to place inside a cache on miss. Consider it a way to achieve the
  ability to create a read-through cache.

  A fallback function should return a Tuple consisting of a `:commit`
  or `:ignore` tag and a value. If the Tuple is tagged `:commit` the
  value will be placed into the cache and then returned. If tagged
  `:ignore` the value will be returned without being written to the
  cache. If you return a value which does not fit this structure, it
  will be assumed that you are committing the value.

  If a fallback function has an arity of 1, the requested entry key
  will be passed through to allow for contextual computation. If a
  function has an arity of 2, the `:provide` option from the global
  `:fallback` cache option will be provided as the second argument.
  This is to allow easy state sharing, such as remote clients. If a
  function has an arity of 0, it will be executed without arguments.

  If a cache has been initialized with a default fallback function
  in the `:fallback` option at cache startup, the third argument to
  this call becomes optional.

  ## Examples

      iex> Cachex.put(:my_cache, "key", "value")
      iex> Cachex.fetch(:my_cache, "key", fn(key) ->
      ...>   { :commit, String.reverse(key) }
      ...> end)
      { :ok, "value" }

      iex> Cachex.fetch(:my_cache, "missing_key", fn(key) ->
      ...>   { :ignore, String.reverse(key) }
      ...> end)
      { :ignore, "yek_gnissim" }

      iex> Cachex.fetch(:my_cache, "missing_key", fn(key) ->
      ...>   { :commit, String.reverse(key) }
      ...> end)
      { :commit, "yek_gnissim" }

  """
  @spec fetch(cache, any, function, Keyword.t) :: { status | :commit | :ignore, any }
  def fetch(cache, key, fallback \\ nil, options \\ []) when is_list(options) do
    Overseer.enforce(cache) do
      case fallback || fallback(cache(cache, :fallback), :default) do
        val when is_function(val) ->
          Actions.Fetch.execute(cache, key, val, options)
        _na ->
          error(:invalid_fallback)
      end
    end
  end

  @doc """
  Retrieves an entry from a cache.

  ## Examples

      iex> Cachex.put(:my_cache, "key", "value")
      iex> Cachex.get(:my_cache, "key")
      { :ok, "value" }

      iex> Cachex.get(:my_cache, "missing_key")
      { :ok, nil }

  """
  @spec get(cache, any, Keyword.t) :: { atom, any }
  def get(cache, key, options \\ []) when is_list(options) do
    Overseer.enforce(cache) do
      Actions.Get.execute(cache, key, options)
    end
  end

  @doc """
  Retrieves and updates an entry in a cache.

  This operation can be seen as an internal mutation, meaning that any previously
  set expiration time is kept as-is.

  This function accepts the same return syntax as fallback functions, in that if
  you return a Tuple of the form `{ :ignore, value }`, the value is returned from
  the call but is not written to the cache. You can use this to abandon writes
  which began eagerly (for example if a key is actually missing).

  ## Examples

      iex> Cachex.put(:my_cache, "key", [2])
      iex> Cachex.get_and_update(:my_cache, "key", &([1|&1]))
      { :ok, [1, 2] }

      iex> Cachex.get_and_update(:my_cache, "missing_key", fn
      ...>   (nil) -> { :ignore, nil }
      ...>   (val) -> { :commit, [ "value" | val ] }
      ...> end)
      { :ok, nil }

  """
  @spec get_and_update(cache, any, function, Keyword.t) :: { status, any }
  def get_and_update(cache, key, update_function, options \\ [])
  when is_function(update_function) and is_list(options) do
    Overseer.enforce(cache) do
      Actions.GetAndUpdate.execute(cache, key, update_function, options)
    end
  end

  @doc """
  Retrieves a list of all entry keys from a cache.

  The order these keys are returned should be regarded as unordered.

  ## Examples

      iex> Cachex.put(:my_cache, "key1", "value1")
      iex> Cachex.put(:my_cache, "key2", "value2")
      iex> Cachex.put(:my_cache, "key3", "value3")
      iex> Cachex.keys(:my_cache)
      { :ok, [ "key2", "key1", "key3" ] }

      iex> Cachex.clear(:my_cache)
      iex> Cachex.keys(:my_cache)
      { :ok, [] }

  """
  @spec keys(cache, Keyword.t) :: { status, [ any ] }
  def keys(cache, options \\ []) when is_list(options) do
    Overseer.enforce(cache) do
      Actions.Keys.execute(cache, options)
    end
  end

  @doc """
  Increments an entry in the cache.

  This will overwrite any value that was previously set against the provided key,
  and overwrite any TTLs which were already set.

  ## Options

    * `:initial`

      </br>
      An initial value to set the key to if it does not exist. This will
      take place *before* the increment call. Defaults to 0.

  ## Examples

      iex> Cachex.put(:my_cache, "my_key", 10)
      iex> Cachex.incr(:my_cache, "my_key")
      { :ok, 11 }

      iex> Cachex.put(:my_cache, "my_new_key", 10)
      iex> Cachex.incr(:my_cache, "my_new_key", 5)
      { :ok, 15 }

      iex> Cachex.incr(:my_cache, "missing_key", 5, initial: 2)
      { :ok, 7 }

  """
  @spec incr(cache, any, integer, Keyword.t) :: { status, integer }
  def incr(cache, key, amount \\ 1, options \\ [])
  when is_integer(amount) and is_list(options) do
    Overseer.enforce(cache) do
      Actions.Incr.execute(cache, key, amount, options)
    end
  end

  @doc """
  Inspects various aspects of a cache.

  These operations should be regarded as debug tools, and should really
  only happen outside of production code (unless absolutely) necessary.

  Accepted options are only provided for convenience and should not be
  heavily relied upon.  They are not part of the public interface
  (despite being documented) and as such  may be removed at any time
  (however this does not mean that they will be).

  Please use cautiously. `inspect/2` is provided mainly for testing purposes and
  so performance isn't as much of a concern.

  ## Options

    * `:cache`

      </br>
      Retrieves the internal cache record for a cache.

      </br>
    * `{ :entry, key }`

      </br>
      Retrieves a raw entry record from inside a cache.

    * `{ :expired, :count }`

      </br>
      Retrieves the number of expired entries which currently live in the cache
      but have not yet been removed by cleanup tasks (either scheduled or lazy).

      </br>
    * `{ :expired, :keys }`

      </br>
      Retrieves the list of expired entry keys which current live in the cache
      but have not yet been removed by cleanup tasks (either scheduled or lazy).

      </br>
    * `{ :janitor, :last }`

      </br>
      Retrieves metadata about the last execution of the Janitor service for
      the specified cache.

      </br>
    * `{ :memory, :bytes }`

      </br>
      Retrieves an approximate memory footprint of a cache in bytes.

      </br>
    * `{ :memory, :binary }`

      </br>
      Retrieves an approximate memory footprint of a cache in binary format.

      </br>
    * `{ :memory, :words }`

      </br>
      Retrieve an approximate memory footprint of a cache as a number of
      machine words.

  ## Examples

      iex> Cachex.inspect(:my_cache, :cache)
      {:ok,
       {:cache, :my_cache, %{}, {:expiration, nil, 3000, true}, {:fallback, nil, nil},
        {:hooks, [], []}, {:limit, nil, Cachex.Policy.LRW, 0.1, []}, false}}

      iex> Cachex.inspect(:my_cache, { :entry, "my_key" } )
      { :ok, { :entry, "my_key", 1475476615662, 1, "my_value" } }

      iex> Cachex.inspect(:my_cache, { :expired, :count })
      { :ok, 0 }

      iex> Cachex.inspect(:my_cache, { :expired, :keys })
      { :ok, [ ] }

      iex> Cachex.inspect(:my_cache, { :janitor, :last })
      { :ok, %{ count: 0, duration: 57, started: 1475476530925 } }

      iex> Cachex.inspect(:my_cache, { :memory, :binary })
      { :ok, "10.38 KiB" }

      iex> Cachex.inspect(:my_cache, { :memory, :bytes })
      { :ok, 10624 }

      iex> Cachex.inspect(:my_cache, { :memory, :words })
      { :ok, 1328 }

  """
  @spec inspect(cache, atom | tuple) :: { status, any }
  def inspect(cache, option) do
    Overseer.enforce(cache) do
      Actions.Inspect.execute(cache, option)
    end
  end

  @doc """
  Invokes a custom command against a cache entry.

  The provided command name must be a valid command which was
  previously attached to the cache in calls to `start_link/3`.

  ## Examples

      iex> import Cachex.Spec
      iex>
      iex> Cachex.start_link(:my_cache, [
      ...>    commands: [
      ...>      last: command(type: :read, execute: &List.last/1)
      ...>    ]
      ...> ])
      iex> Cachex.put(:my_cache, "my_list", [ 1, 2, 3 ])
      iex> Cachex.invoke(:my_cache, :last, "my_list")
      { :ok, 3 }

  """
  @spec invoke(cache, atom, any, Keyword.t) :: any
  def invoke(cache, cmd, key, options \\ []) when is_list(options) do
    Overseer.enforce(cache) do
      Actions.Invoke.execute(cache, cmd, key, options)
    end
  end

  @doc """
  Deserializes a cache from a location on a filesystem.

  This operation will read the current state of a cache from a provided
  location on a filesystem. This function will only understand files
  which have previously been created using `dump/3`.

  It is the responsibility of the user to ensure that the location is
  able to be read from, not the responsibility of Cachex.

  ## Examples

      iex> Cachex.put(:my_cache, "my_key", 10)
      iex> Cachex.dump(:my_cache, "/tmp/my_backup")
      iex> Cachex.clear(:my_cache)
      iex> Cachex.load(:my_cache, "/tmp/my_backup")
      { :ok, true }

  """
  @spec load(cache, binary, Keyword.t) :: { status, any }
  def load(cache, path, options \\ [])
  when is_binary(path) and is_list(options) do
    Overseer.enforce(cache) do
      Actions.Load.execute(cache, path, options)
    end
  end

  @doc """
  Removes an expiration time from an entry in a cache.

  ## Examples

      iex> Cachex.put(:my_cache, "key", "value", ttl: 1000)
      iex> Cachex.persist(:my_cache, "key")
      { :ok, true }

      iex> Cachex.persist(:my_cache, "missing_key")
      { :ok, false }

  """
  @spec persist(cache, any, Keyword.t) :: { status, boolean }
  def persist(cache, key, options \\ []) when is_list(options),
    do: expire(cache, key, nil, via({ :persist, [ key, options ] }, options))

  @doc """
  Triggers a cleanup of all expired entries in a cache.

  This can be used to implement custom eviction policies rather than
  relying on the internal Janitor service. Take care when using this
  method though; calling `purge/2` manually will result in a purge
  firing inside the calling process.

  ## Examples

      iex> Cachex.purge(:my_cache)
      { :ok, 15 }

  """
  @spec purge(cache, Keyword.t) :: { status, number }
  def purge(cache, options \\ []) when is_list(options) do
    Overseer.enforce(cache) do
      Actions.Purge.execute(cache, options)
    end
  end

  @doc """
  Places an entry in a cache.

  This will overwrite any value that was previously set against the provided key,
  and overwrite any TTLs which were already set.

  ## Options

    * `:ttl`

      </br>
      An expiration time to set for the provided key (time-to-line), overriding
      any default expirations set on a cache. This value should be in milliseconds.

  ## Examples

      iex> Cachex.put(:my_cache, "key", "value")
      { :ok, true }

      iex> Cachex.put(:my_cache, "key", "value", ttl: :timer.seconds(5))
      iex> Cachex.ttl(:my_cache, "key")
      { :ok, 5000 }

  """
  # TODO: maybe rename TTL to be expiration?
  @spec put(cache, any, any, Keyword.t) :: { status, boolean }
  def put(cache, key, value, options \\ []) when is_list(options) do
    Overseer.enforce(cache) do
      Actions.Put.execute(cache, key, value, options)
    end
  end

  @doc """
  Places a batch of entries in a cache.

  This operates in the same way as `put/4`, except that multiple keys can be
  inserted in a single atomic batch. This is a performance gain over writing
  keys using multiple calls to `put/4`, however it's a performance penalty
  when writing a single key pair due to some batching overhead.

  ## Options

    * `:ttl`

      </br>
      An expiration time to set for the provided keys (time-to-line), overriding
      any default expirations set on a cache. This value should be in milliseconds.

  ## Examples

      iex> Cachex.put_many(:my_cache, [ { "key", "value" } ])
      { :ok, true }

      iex> Cachex.put_many(:my_cache, [ { "key", "value" } ], ttl: :timer.seconds(5))
      iex> Cachex.ttl(:my_cache, "key")
      { :ok, 5000 }

  """
  # TODO: maybe rename TTL to be expiration?
  @spec put_many(cache, [ { any, any } ], Keyword.t) :: { status, boolean }
  def put_many(cache, pairs, options \\ [])
  when is_list(pairs) and is_list(options) do
    Overseer.enforce(cache) do
      Actions.PutMany.execute(cache, pairs, options)
    end
  end

  @doc """
  Refreshes an expiration for an entry in a cache.

  Refreshing an expiration will reset the existing expiration with an offset
  from the current time - i.e. if you set an expiration of 5 minutes and wait
  3 minutes before refreshing, the entry will expire 8 minutes after the initial
  insertion.

  ## Examples

      iex> Cachex.put(:my_cache, "my_key", "my_value", ttl: :timer.seconds(5))
      iex> :timer.sleep(4)
      iex> Cachex.ttl(:my_cache, "my_key")
      { :ok, 1000 }

      iex> Cachex.refresh(:my_cache, "my_key")
      iex> Cachex.ttl(:my_cache, "my_key")
      { :ok, 5000 }

      iex> Cachex.refresh(:my_cache, "missing_key")
      { :ok, false }

  """
  @spec refresh(cache, any, Keyword.t) :: { status, boolean }
  def refresh(cache, key, options \\ []) when is_list(options) do
    Overseer.enforce(cache) do
      Actions.Refresh.execute(cache, key, options)
    end
  end

  @doc """
  Resets a cache by clearing the keyspace and restarting any hooks.

  ## Options

    * `:hooks`

      </br>
      A whitelist of hooks to reset on the cache instance (call the
      initialization phase of a hook again). This will default to
      resetting all hooks associated with a cache, which is usually
      the desired behaviour.

      </br>
    * `:only`

      </br>
      A whitelist of components to reset, which can currently contain
      either the `:cache` or `:hooks` tag to determine what to reset.
      This will default to `[ :cache, :hooks ]`.

  ## Examples

      iex> Cachex.put(:my_cache, "my_key", "my_value")
      iex> Cachex.reset(:my_cache)
      iex> Cachex.size(:my_cache)
      { :ok, 0 }

      iex> Cachex.reset(:my_cache, [ only: :hooks ])
      { :ok, true }

      iex> Cachex.reset(:my_cache, [ only: :hooks, hooks: [ MyHook ] ])
      { :ok, true }

      iex> Cachex.reset(:my_cache, [ only: :cache ])
      { :ok, true }

  """
  @spec reset(cache, Keyword.t) :: { status, true }
  def reset(cache, options \\ []) when is_list(options) do
    Overseer.enforce(cache) do
      Actions.Reset.execute(cache, options)
    end
  end

  @doc """
  Deprecated implementation delegate of `put/4`.
  """
  @deprecated "Please migrate to using put/4 instead"
  def set(cache, key, value, options \\ []),
    do: put(cache, key, value, options)

  @doc """
  Deprecated implementation delegate of `put_many/3`.
  """
  @deprecated "Please migrate to using put_many/3 instead"
  def set_many(cache, pairs, options \\ []),
    do: put_many(cache, pairs, options)

  @doc """
  Retrieves the total size of a cache.

  This does not take into account the expiration time of any entries
  inside the cache. Due to this, this call is O(1) rather than the more
  expensive O(n) algorithm used by `count/3`. Which you use depends on
  exactly what you want the returned number to represent.

  ## Examples

      iex> Cachex.put(:my_cache, "key1", "value1")
      iex> Cachex.put(:my_cache, "key2", "value2")
      iex> Cachex.put(:my_cache, "key3", "value3")
      iex> Cachex.size(:my_cache)
      { :ok, 3 }

  """
  @spec size(cache, Keyword.t) :: { status, number }
  def size(cache, options \\ []) when is_list(options) do
    Overseer.enforce(cache) do
      Actions.Size.execute(cache, options)
    end
  end

  @doc """
  Retrieves statistics about a cache.

  This will only provide statistics if the `:stats` option was
  provided on cache startup in `start_link/3`.

  ## Options

    * `:for`

      </br>
      Allows customization of exactly which statistics to retrieve.

  ## Examples

      iex> Cachex.stats(:my_cache)
      {:ok, %{creationDate: 1460312824198, missCount: 1, opCount: 2, setCount: 1}}

      iex> Cachex.stats(:my_cache, for: :get)
      {:ok, %{creationDate: 1460312824198, get: %{missing: 1}}}

      iex> Cachex.stats(:my_cache, for: :raw)
      {:ok,
       %{get: %{missing: 1}, global: %{missCount: 1, opCount: 2, setCount: 1},
         meta: %{creationDate: 1460312824198}, set: %{true: 1}}}

      iex> Cachex.stats(:my_cache, for: [ :get, :set ])
      {:ok, %{creationDate: 1460312824198, get: %{missing: 1}, set: %{true: 1}}}

      iex> Cachex.stats(:cache_with_no_stats)
      { :error, :stats_disabled }

  """
  @spec stats(cache, Keyword.t) :: { status, %{ } }
  def stats(cache, options \\ []) when is_list(options) do
    Overseer.enforce(cache) do
      Actions.Stats.execute(cache, options)
    end
  end

  @doc """
  Creates a `Stream` of entries in a cache.

  The returned stream operates entirely on an ETS level in order
  to provide a moving view of a cache. As such, if you wish to
  operate on any keys as a result of the stream, please execute
  your modifications inside a transactional context.

  ## Options

    * `:of`

      </br>
      Specifies the format of the entries to stream, allowing the
      caller to customize the seeded entry format. This will usually
      be `:key` or `:value` as users only interact with those fields
      directly. This can also be a Tuple and defaults to the pair of
      `{ :key, :value }`.

  ## Examples

      iex> Cachex.put(:my_cache, "a", 1)
      iex> Cachex.put(:my_cache, "b", 2)
      iex> Cachex.put(:my_cache, "c", 3)
      {:ok, true}

      iex> :my_cache |> Cachex.stream! |> Enum.to_list
      [{"b", 2}, {"c", 3}, {"a", 1}]

      iex> :my_cache |> Cachex.stream!(of: :key) |> Enum.to_list
      ["b", "c", "a"]

      iex> :my_cache |> Cachex.stream!(of: :value) |> Enum.to_list
      [2, 3, 1]

      iex> :my_cache |> Cachex.stream!(of: { :key, :ttl }) |> Enum.to_list
      [{"b", nil}, {"c", nil}, {"a", nil}]

  """
  @spec stream(cache, Keyword.t) :: { status, Enumerable.t }
  def stream(cache, options \\ []) when is_list(options) do
    Overseer.enforce(cache) do
      Actions.Stream.execute(cache, options)
    end
  end

  @doc """
  Takes an entry from a cache.

  This is conceptually equivalent to running `get/3` followed
  by an atomic `del/3` call.

  ## Examples

      iex> Cachex.put(:my_cache, "key", "value")
      iex> Cachex.take(:my_cache, "key")
      { :ok, "value" }

      iex> Cachex.get(:my_cache, "key")
      { :ok, nil }

      iex> Cachex.take(:my_cache, "missing_key")
      { :ok, nil }

  """
  @spec take(cache, any, Keyword.t) :: { status, any }
  def take(cache, key, options \\ []) when is_list(options) do
    Overseer.enforce(cache) do
      Actions.Take.execute(cache, key, options)
    end
  end

  @doc """
  Updates the last write time on a cache entry.

  This is very similar to `refresh/3` except that the expiration
  time is maintained inside the record (using a calculated offset).
  """
  @spec touch(cache, any, Keyword.t) :: { status, boolean }
  def touch(cache, key, options \\ []) when is_list(options) do
    Overseer.enforce(cache) do
      Actions.Touch.execute(cache, key, options)
    end
  end

  @doc """
  Executes multiple functions in the context of a transaction.

  This will operate in the same way as `execute/3`, except that writes
  to the specified keys will be blocked on the execution of this transaction.

  The keys parameter should be a list of keys you wish to lock whilst
  your transaction is executed. Any keys not in this list can still be
  written even during your transaction.

  ## Examples

      iex> Cachex.put(:my_cache, "key1", "value1")
      iex> Cachex.put(:my_cache, "key2", "value2")
      iex> Cachex.transaction(:my_cache, fn(worker) ->
      ...>   val1 = Cachex.get(worker, "key1")
      ...>   val2 = Cachex.get(worker, "key2")
      ...>   [val1, val2]
      ...> end)
      { :ok, [ "value1", "value2" ] }

  """
  @spec transaction(cache, [ any ], function, Keyword.t) :: { status, any }
  def transaction(cache, keys, operation, options \\ [])
  when is_function(operation, 1) and is_list(keys) and is_list(options) do
    Overseer.enforce(cache) do
      trans_cache =
        case cache(cache, :transactional) do
          true  -> cache
          false ->
            cache
            |> cache(:name)
            |> Overseer.update(&cache(&1, transactional: true))
        end

      Actions.Transaction.execute(trans_cache, keys, operation, options)
    end
  end

  @doc """
  Retrieves the expiration for an entry in a cache.

  This is a millisecond value (if set) representing the time a
  cache entry has left to live in a cache. It can return `nil`
  if the entry does not have a set expiration.

  ## Examples

      iex> Cachex.ttl(:my_cache, "my_key")
      { :ok, 13985 }

      iex> Cachex.ttl(:my_cache, "my_key_with_no_ttl")
      { :ok, nil }

      iex> Cachex.ttl(:my_cache, "missing_key")
      { :ok, nil }

  """
  @spec ttl(cache, any, Keyword.t) :: { status, number }
  def ttl(cache, key, options \\ []) when is_list(options) do
    Overseer.enforce(cache) do
      Actions.Ttl.execute(cache, key, options)
    end
  end

  @doc """
  Updates an entry in a cache.

  Unlike `get_and_update/4`, this does a blind overwrite of a value.

  This operation can be seen as an internal mutation, meaning that any previously
  set expiration time is kept as-is.

  ## Examples

      iex> Cachex.put(:my_cache, "key", "value")
      iex> Cachex.get(:my_cache, "key")
      { :ok, "value" }

      iex> Cachex.update(:my_cache, "key", "new_value")
      iex> Cachex.get(:my_cache, "key")
      { :ok, "new_value" }

      iex> Cachex.update(:my_cache, "missing_key", "new_value")
      { :ok, false }

  """
  @spec update(cache, any, any, Keyword.t) :: { status, any }
  def update(cache, key, value, options \\ []) when is_list(options) do
    Overseer.enforce(cache) do
      Actions.Update.execute(cache, key, value, options)
    end
  end

  ###############
  # Private API #
  ###############

  # Determines whether the Cachex application has been started.
  #
  # This will return an error if the application has not been
  # started, otherwise a truthy result will be returned.
  defp ensure_started do
    if Overseer.started?() do
      { :ok, true }
    else
      error(:not_started)
    end
  end

  # Determines if a cache name is already in use.
  #
  # If the name is in use, we return an error.
  defp ensure_unused(cache) do
    case GenServer.whereis(cache) do
      nil -> { :ok, true }
      pid -> { :error, { :already_started, pid } }
    end
  end

  # Configures the environment for a new cache.
  #
  # This will first parse all provided options into a cache record, if
  # the options provided are valid (errors if not). Then we create a
  # new base ETS table to validate the ETS options, before deleting
  # the table and reporting that everything is ready.
  #
  # At a glance this seems very strange, but we use Eternal to manage
  # our table and so the Supervisor would simply crash on invalid
  # table options, which does not allow us to explain to the user.
  defp setup_env(name, options) when is_list(options) do
    with { :ok, cache } <- Options.parse(name, options) do
      try do
        :ets.new(name, [ :named_table | const(:table_options) ])
        :ets.delete(name)
        { :ok, cache }
      rescue
        _ -> error(:invalid_option)
      end
    end
  end

  # Unwraps a command result into an unsafe form.
  #
  # This is used alongside the Unsafe library to generate shorthand
  # bang functions for the API. This will expand error messages and
  # remove the binding Tuples in order to allow for easy piping of
  # results from cache calls.
  defp unwrap_unsafe({ :error, value }) when is_atom(value),
    do: raise ExecutionError, message: Errors.long_form(value)
  defp unwrap_unsafe({ :error, value }) when is_binary(value),
    do: raise ExecutionError, message: value
  defp unwrap_unsafe({ _state, value }),
    do: value
end
