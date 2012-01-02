%%%=============================================================================
%%% @doc
%%%
%%% This server is the head of the autumn application. It will do it
%%% (the dependency injection and all the rest).
%%%
%%% @end
%%%=============================================================================

-module(autumn).

%%%=============================================================================
%%% Exports
%%%=============================================================================

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% API that can be called only by processes created by an autumn server
-export([add_factory/1,
	 remove_factory/1,
	 push/2,
	 push/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%%%=============================================================================
%%% Includes
%%%=============================================================================

-include("autumn.hrl").

%%%=============================================================================
%%% Types
%%%=============================================================================

-define(SERVER, ?MODULE).
-registered([?SERVER]).

-type factory_id() :: term().

-record(state,
	{factories = dict:new() :: dict(),%% id -> #factory{}
	 %% {factory_id(), [au_item:ref()]} -> pid()
	 active    = dict:new() :: dict(),
	 items     = dict:new() :: dict(), %% au_item:key() -> au_item:ref()
	 down_handler = dict:new() :: dict() %% reference() -> fun/2
	}).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% Start the server.
%% @end
%%------------------------------------------------------------------------------
-spec start_link() ->
			{ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%=============================================================================
%%% API for processes managed by autumn.
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% Adds factory function defined by a module and a function.
%%
%% The same Id value must be passed to `remove_factory' to remove the
%% factory.
%%
%% The function defined by the last three parameters is supposed to
%% start and link a process that requires the start args referred to
%% by the list of ids passed as second parameter. The function will be
%% invoked for every kosher set of start arguments and the resulting
%% process will be terminated as soon as an item passed in as start
%% argument is invalidated.
%%
%% The arguments of the function `M:F' begin with `ExtraArgs' followed
%% by a proplist of the items requested by the first parameter.
%%
%% Return values:
%%
%%  * `ok' the factory was added
%%  * `{error, {already_added, Id}}'
%%
%% @end
%% ------------------------------------------------------------------------------
-spec add_factory(Factory  :: #factory{}) ->
			 ok | {error, {already_added, term()}}.
add_factory(Factory) ->
    gen_server:call(?SERVER,
		    {add_factory, Factory}).

%%------------------------------------------------------------------------------
%% @doc
%%
%% Removes a factory definition added by `add_factory'. The processes
%% started by the factory will continue to run.
%%
%% Return values:
%%
%%  * `ok' the factory was removed successfully
%%  * `{error, {not_found, Id}}'
%%
%% @end
%%------------------------------------------------------------------------------
-spec remove_factory(Id :: term()) ->
			 ok | {error, {not_found, Id :: term()}}.
remove_factory(Id) ->
    gen_server:call(?SERVER, {remove_factory, Id}).

%%------------------------------------------------------------------------------
%% @doc
%%
%% Provide an item, that factories may use to start new
%% processes. NOTE: A processes MUST NOT push an item that was
%% injected as start argument. There is no reason why this should be
%% necessary. When this is done some autumn functions might get into
%% infinite loops.
%%
%% @end
%% ------------------------------------------------------------------------------
-spec push(au_item:ref()) ->
		      ok.
push(Item) ->
    gen_server:cast(?SERVER, {push, Item}).

%%------------------------------------------------------------------------------
%% @doc
%%
%% Provide an item, that factories may use to start new
%% processes. This is a conveniece function that will create a new
%% item process and link it with the calling process.
%%
%% @end
%% ------------------------------------------------------------------------------
-spec push(au_item:key(), au_item:value()) ->
		      {ok, au_item:ref()}.
push(Key, Value) ->
    Item = au_item:new_link(Key, Value),
    gen_server:cast(?SERVER, {push, Item}),
    {ok, Item}.

%%%=============================================================================
%%% gen_server Callbacks
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
init(_) ->
    process_flag(trap_exit, true),
    {ok, #state{}}.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
handle_call({add_factory, Factory =  #factory{id = Id}}, _, S) ->
    case get_factory_by_id(Id, S) of
	{ok, _} ->
	    {reply, {error, {already_added, Id}}, S};
	error ->
	    error_logger:info_report(autumn, [{adding_factory, Id}]),
	    {reply, ok, add_factory(Factory, S)}
    end;

handle_call({remove_factory, Id}, _, S) ->
    case get_factory_by_id(Id, S) of
	{ok, _} ->
	    error_logger:info_report(autumn, [{removing_factory, Id}]),
	    {reply, ok, remove_factory(Id, S)};
	error ->
	    {reply, {error, {not_found, Id}}, S}
    end.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
handle_cast({push, Item}, S) ->
    error_logger:info_report(autumn, [{pushed, Item}]),
    S2 = add_item(Item, S),
    Factories = find_factory_by_dependency(au_item:key(Item), S2),
    S3 = lists:foldl(fun apply_factory/2, S2, Factories),
    {noreply, S3}.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
handle_info({'DOWN',Ref,_,_,Reason}, #state{down_handler=DH} = S) ->
    S2 = (dict:fetch(Ref, DH))(S, Reason),
    {noreply, S2#state{down_handler = dict:erase(Ref, DH)}}.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%=============================================================================
%%% Internal Functions
%%%=============================================================================

%%%                                                            Factory Functions

%%------------------------------------------------------------------------------
%% @private Look up the a factory by its id
%%-----------------------------------------------------------------------------
get_factory_by_id(Id, #state{factories = Fs}) ->
    dict:find(Id, Fs).

%%------------------------------------------------------------------------------
%% @private Add a factory to the set of factories.If possible apply factory.
%%------------------------------------------------------------------------------
add_factory(Factory = #factory{id = Id}, S) ->
    Fs = S#state.factories,
    apply_factory(Factory, S#state{factories = dict:store(Id, Factory, Fs)}).

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
remove_factory(Id, S) ->
    Fs = S#state.factories,
    S#state{factories = dict:erase(Id, Fs)}.

%%------------------------------------------------------------------------------
%% @doc
%% This invokes the factory to create a process for every unique and
%% valid set of start args.
%% @end
%%------------------------------------------------------------------------------
apply_factory(F, S) ->
    Reqs = F#factory.req,
    %% fetch all items for all required start arguments
    StartArgsValues= [get_values_by_key(R, S) || R <- Reqs],

    %% create the cartesian product of all types of start arguments...
    StartArgsSets = [StartArgsSet || StartArgsSet <- perms(StartArgsValues),
				     %% .. filtering start arg sets alredy used
				     not is_active(F, StartArgsSet, S)],

    %% start a child for every set of start args
    lists:foldl(start_factory_child(F), S, StartArgsSets).

%%------------------------------------------------------------------------------
%% @private Create all permutations of a list of lists.
%%------------------------------------------------------------------------------
-spec perms([[term()]]) -> [[term()]].
perms([S|Sets]) ->
    [[X|P] || X <- S, P <- perms(Sets)];
perms([]) ->
    [[]].

%%------------------------------------------------------------------------------
%% @doc
%% Returns `true' if a factory has already been applied to a start arg set.
%% @end
%%------------------------------------------------------------------------------
is_active(#factory{id = Id}, StartArgsSet, S) ->
    not (dict:find({Id, StartArgsSet}, S#state.active) =:= error).

%%------------------------------------------------------------------------------
%% @doc
%% Starts a new child of a factory for some start args and adds it to the state.
%% @end
%%------------------------------------------------------------------------------
start_factory_child(F) ->
    fun(StartArgSet, S) ->
	    error_logger:info_report(autumn, [{starting_child_of,
					       F#factory.id}]),
	    {ok, Pid} = au_factory:start_child(F, StartArgSet),
	    S#state{active = dict:store({F#factory.id, StartArgSet}, Pid,
					S#state.active)}
    end.

%%------------------------------------------------------------------------------
%% @doc
%% Fetches a list of items associated to an item key.
%% @end
%%------------------------------------------------------------------------------
get_values_by_key(ItemId, S) ->
    case dict:find(ItemId, S#state.items) of
	error ->
	    [];
	{ok, Items} ->
	    Items
    end.

%%------------------------------------------------------------------------------
%% @doc
%% Return a list of factories that depend on a specific item key.
%% @end
%%------------------------------------------------------------------------------
-spec find_factory_by_dependency(au_item:key(), #state{}) ->
					[#factory{}].
find_factory_by_dependency(K, #state{factories = Fs}) ->
    [F || {_,F} <- dict:to_list(Fs),
	  lists:member(K, F#factory.req)].

%%------------------------------------------------------------------------------
%% @doc
%% Add an item to the set of available items.
%% @end
%%------------------------------------------------------------------------------
-spec add_item(au_item:ref(), #state{}) ->
		      #state{}.
add_item(Item, S) ->
    K = au_item:key(Item),
    Ref = au_item:monitor(Item),
    ItemDown = fun(State, Reason) ->
		       remove_item(Item, State, Reason)
	       end,
    ItemsWithSameKey = get_values_by_key(K, S),
    S#state{
      items = dict:store(K, [Item|ItemsWithSameKey], S#state.items),
      down_handler = dict:store(Ref, ItemDown, S#state.down_handler)
     }.

%%------------------------------------------------------------------------------
%% @doc
%% Remove an item from the set of available items. No effect if the item
%% is not available. All depending processes will be terminated.
%% @end
%%------------------------------------------------------------------------------
-spec remove_item(au_item:ref(), #state{}, term()) ->
			 #state{}.
remove_item(Item, S, Reason) ->
    error_logger:info_report(autumn, [{remove_item, Item}]),
    NewVs = [V || V <- get_values_by_key(au_item:key(Item), S),
		  V =/= Item],
    S2 = S#state{items = dict:store(au_item:key(Item), NewVs, S#state.items)},
    stop_dependent(Item, S2, Reason).

%%------------------------------------------------------------------------------
%% @doc
%% Exits all factory instances that depend on a specific item.
%% @end
%%------------------------------------------------------------------------------
-spec stop_dependent(au_item:ref(), #state{}, term()) ->
			     #state{}.
stop_dependent(I, S = #state{active = As}, Reason) ->
    S#state{active =
		dict:filter(fun({Id, Reqs}, Pid) ->
				    case lists:member(I, Reqs) of
					true ->
					    error_logger:info_report(
					      autumn,
					      [{stopping_child_of, Id}]),
					    exit(Pid, Reason),
					    false;
					_ ->
					    true
				    end
			    end,
			    As)}.
