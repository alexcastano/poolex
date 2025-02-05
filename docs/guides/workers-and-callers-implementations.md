# Workers and callers implementations

`Poolex` operates with two concepts: `callers` and `workers`. In both cases, we are talking about processes.

## Callers

`Callers` are processes that have requested to get a worker (used `run/3` or `run!/3`). Each pool keeps the information about `callers` to distribute workers to them when they are free.

> ### Caller's typespec {: .warning}
>
> Caller's typespec is `GenServer.from()` not a `pid()`.

The implementation of the caller storage structure should be conceptually similar to a queue since by default we want to give workers in the order they are requested. But this logic can be easily changed by writing your implementation.

Behaviour of callers collection described [here](https://hexdocs.pm/poolex/Poolex.Callers.Behaviour.html).

### Behaviour callbacks

| Callback          | Description                                                                                                          |
|-------------------|----------------------------------------------------------------------------------------------------------------------|
| `init/0`          | Returns `state` (any data structure) which will be passed as the first argument to all other functions.              |
| `add/2`           | Adds caller to `state` and returns a new state.                                                                      |
| `empty?/1`        | Returns `true` if the `state` is empty, `false` otherwise.                                                           |
| `pop/1`           | Removes one of the callers from `state` and returns it as `{caller, state}`. Returns `:empty` if the state is empty. |
| `remove_by_pid/2` | Removes given caller by caller's pid from `state` and returns a new state.                                           |
| `to_list/1`       | Returns list of callers.                                                                                             |

### Callers implementations out of the box

| Module                            | Description                                    | Source                                                                                           | Default? |
|-----------------------------------|------------------------------------------------|--------------------------------------------------------------------------------------------------|----------|
| `Poolex.Callers.Impl.ErlangQueue` | `FIFO` implementation based on `:erlang.queue` | [link](https://github.com/general-CbIC/poolex/blob/main/lib/poolex/callers/impl/erlang_queue.ex) | ✅       |

## Workers

**Workers** are processes launched in a pool. `Poolex` works with two collections of workers:

1. `IdleWorkers` -- Free processes that can be given to callers upon request.
2. `BusyWorkers` -- Processes that are currently processing the caller's request.

For both cases, the default implementation is based on lists. But it is possible to set different implementations for them.

Behaviour of workers collection described [here](https://hexdocs.pm/poolex/Poolex.Workers.Behaviour.html).

### Behaviour callbacks

| Callback    | Description                                                                                                      |
|-------------|------------------------------------------------------------------------------------------------------------------|
| `init/0`    | Returns `state` (any data structure) which will be passed as the first argument to all other functions.          |
| `init/1`    | Same as `init/0` but returns `state` initialized with a passed list of workers.                                  |
| `add/2`     | Adds worker's pid to `state` and returns a new state.                                                            |
| `member?/2` | Returns `true` if given worker contained in the `state`, `false` otherwise.                                      |
| `remove/2`  | Removes given worker from `state` and returns new state.                                                         |
| `count/1`   | Returns the number of workers in the state.                                                                      |
| `to_list/1` | Returns list of workers pids.                                                                                    |
| `empty?/1`  | Returns `true` if the `state` is empty, `false` otherwise.                                                       |
| `pop/1`     | Removes one of workers from `state` and returns it as `{caller, state}`. Returns `:empty` if the state is empty. |

### Workers implementations out of the box

| Module                            | Description                                    | Source                                                                                           | Default? |
|-----------------------------------|------------------------------------------------|--------------------------------------------------------------------------------------------------|----------|
| `Poolex.Workers.Impl.List`        | `LIFO` implementation based on Elixir's `List` | [link](https://github.com/general-CbIC/poolex/blob/main/lib/poolex/workers/impl/list.ex)         | ✅       |
| `Poolex.Workers.Impl.ErlangQueue` | `FIFO` implementation based on `:erlang.queue` | [link](https://github.com/general-CbIC/poolex/blob/main/lib/poolex/workers/impl/erlang_queue.ex) | ❌       |

## Writing custom implementations

It's quite simple when using the [Behaviours](https://elixir-lang.org/getting-started/typespecs-and-behaviours.html#behaviours) mechanism in Elixir.

For example, you want to define a new implementation for callers. To do this, you need to create a module that inherits the [Poolex.Callers.Behaviour](../../lib/poolex/callers/behaviour.ex) and implement all its functions.

```elixir
defmodule MyApp.MyAmazingCallersImpl do
  @behaviour Poolex.Callers.Behaviour

  def init, do: {}
  def add(state, caller), do: #...
end
```

If you have any ideas about what implementations can be added to the library or how to improve existing ones, then please [create an issue](https://github.com/general-CbIC/poolex/issues/new)!

### Configuring custom implementations

After that, you need to provide your module names to Poolex initialization:

```elixir
Poolex.child_spec(
  pool_id: :some_pool,
  worker_module: SomeWorker,
  workers_count: 10,
  waiting_callers_impl: MyApp.MyAmazingCallersImpl
)
```

That's it! Your implementation will be used in launched pool.

The configuration for workers might look like this:

```elixir
Poolex.child_spec(
  pool_id: :some_pool,
  worker_module: SomeWorker,
  workers_count: 10,
  busy_workers_impl: MyApp.PerfectBusyWorkersImpl,
  idle_workers_impl: MyApp.FancyIdleWorkersImpl
)
```
