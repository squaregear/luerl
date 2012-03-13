%% Copyright (c) 2012 Robert Virding. All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%%
%% 1. Redistributions of source code must retain the above copyright
%%    notice, this list of conditions and the following disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%%
%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
%% "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
%% LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
%% FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
%% COPYRIGHT HOLDERS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
%% INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
%% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
%% LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
%% CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
%% ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
%% POSSIBILITY OF SUCH DAMAGE.

%% File    : luerl_eval.erl
%% Author  : Robert Virding
%% Purpose : A very basic LUA 5.2 VM emulator.

-module(luerl_emul).

-include("luerl.hrl").

%% Basic interface.
-export([init/0,chunk/2,funchunk/2,funchunk/3,gc/1]).

-export([emul/3]).

%% Internal functions which can be useful "outside".
-export([alloc_table/2,functioncall/3,getmetamethod/3,getmetamethod/4]).

%% Currently unused internal functions, to suppress warnings.
-export([alloc_table/1,set_local_keys/3,set_local_keys_tab/3,set_name_env/4]).

-import(luerl_lib, [lua_error/1]).		%Shorten this

%%-define(DP(F,As), io:format(F, As)).
-define(DP(F, A), ok).

%% init() -> State.
%% Initialise the basic state.

init() ->
    St0 = #luerl{meta=#meta{},env=[],locf=false,tag=make_ref()},
    %% Initialise the table handling.
    St1 = St0#luerl{tabs=?MAKE_TABLE(),free=[],next=0},
    %% Allocate the _G table and initialise the environment
    {_G,St2} = luerl_basic:install(St1),	%Allocate base environment
    St3 = push_env(_G, St2),
    St4 = set_local_name('_G', _G, St3),	%Set _G to itself
    %% Add the other standard libraries.
    St5 = alloc_libs([{<<"math">>,luerl_math},
		      {<<"io">>,luerl_io},
		      {<<"os">>,luerl_os},
		      {<<"string">>,luerl_string},
		      {<<"table">>,luerl_table}], St4),
    St5.

alloc_libs(Libs, St) ->
    Fun = fun ({Key,Mod}, St0) ->
		  {T,St1} = Mod:install(St0),
		  set_local_key(Key, T, St1)
	  end,
    lists:foldl(Fun, St, Libs).

%% alloc_env(State) -> {Env,State}.
%% alloc_env(InitialTab, State) -> {Env,State}.
%% push_env(Env, State) -> {Env,State}.
%% pop_env(State) -> State.

alloc_env(St) -> alloc_env(orddict:new(), St).

alloc_env(Itab, St) -> alloc_table(Itab, St).

push_env(#tref{}=T, #luerl{env=Es}=St) ->
    St#luerl{env=[T|Es]}.

pop_env(#luerl{env=[_|Es]}=St) ->
    St#luerl{env=Es}.

%% alloc_table(State) -> {Tref,State}.
%% alloc_table(InitialTable, State) -> {Tref,State}.
%% free_table(Tref, State) -> State.

alloc_table(St) -> alloc_table(orddict:new(), St).

alloc_table(Itab, #luerl{tabs=Ts0,free=[N|Ns]}=St) ->
    Ts1 = ?SET_TABLE(N, #table{t=Itab,m=nil}, Ts0),
    {#tref{i=N},St#luerl{tabs=Ts1,free=Ns}};
alloc_table(Itab, #luerl{tabs=Ts0,free=[],next=N}=St) ->
    Ts1 = ?SET_TABLE(N, #table{t=Itab,m=nil}, Ts0),
    {#tref{i=N},St#luerl{tabs=Ts1,next=N+1}}.

free_table(#tref{i=N}, #luerl{tabs=Ts0,free=Ns}=St) ->
    Ts1 = ?DEL_TABLE(N, Ts0),
    St#luerl{tabs=Ts1,free=[N|Ns]}.

%% set_table_name(Name, Value, Tref, State) -> State.
%% set_table_key(Key, Value, Tref, State) -> State.
%% get_table_name(Name, Tref, State) -> {Val,State}.
%% get_table_key(Key, Tref, State) -> {Val,State}.
%%  Access tables, as opposed to the environment (which are also
%%  tables). Setting a value to 'nil' will clear it from the table.

set_table_name(Name, Val, Tab, St) ->
    set_table_key(atom_to_binary(Name, latin1), Val, Tab, St).

set_table_key(Key, Val, #tref{i=N}, #luerl{tabs=Ts0}=St) ->
    #table{t=Tab0,m=Meta} = ?GET_TABLE(N, Ts0),	%Get the table
    case orddict:find(Key, Tab0) of
	{ok,_} ->
%% 	    Tab1 = if Val =:= nil -> orddict:erase(Key, Tab0);
%% 		      true -> orddict:store(Key, Val, Tab0)
%% 		   end,
	    Tab1 = orddict:store(Key, Val, Tab0),
	    Ts1 = ?SET_TABLE(N, #table{t=Tab1,m=Meta}, Ts0),
	    St#luerl{tabs=Ts1};
	error ->
	    case getmetamethod_tab(Meta, <<"__newindex">>, Ts0) of
		nil ->
		    Tab1 = orddict:store(Key, Val, Tab0),
		    Ts1 = ?SET_TABLE(N, #table{t=Tab1,m=Meta}, Ts0),
		    St#luerl{tabs=Ts1};
		Meth when element(1, Meth) =:= function ->
		    functioncall(Meth, [Key,Val], St);
		Meth -> set_table_key(Key, Val, Meth, St)
	    end
    end;
set_table_key(Key, _, Tab, _) ->
    lua_error({illegal_index,Tab,Key}).

get_table_name(Name, Tab, St) ->
    get_table_key(atom_to_binary(Name, latin1), Tab, St).

get_table_key(Key, #tref{i=N}=T, #luerl{tabs=Ts}=St) ->
    #table{t=Tab,m=Meta} = ?GET_TABLE(N, Ts),	%Get the table.
    case orddict:find(Key, Tab) of
	{ok,Val} -> {Val,St};
	error ->
	    %% Key not present so try metamethod
	    case getmetamethod_tab(Meta, <<"__index">>, Ts) of
		nil -> {nil,St};
		Meth when element(1, Meth) =:= function ->
		    {Vs,St1} = functioncall(Meth, [T,Key], St),
		    {first_value(Vs),St1};	%Only one value
		Meth ->				%Recurse down the metatable
		    get_table_key(Key, Meth, St)
	    end
    end;
get_table_key(Key, Tab, St) ->			%Just find the metamethod
    case getmetamethod(Tab, <<"__index">>, St) of
	nil -> lua_error({illegal_index,Tab,Key});
	Meth when element(1, Meth) =:= function ->
	    {Vs,St1} = functioncall(Meth, [Tab,Key], St),
	    {first_value(Vs),St1};		%Only one value
	Meth ->					%Recurse down the metatable
	    get_table_key(Key, Meth, St)
    end.

%% set_local_name(Name, Val, State) -> State.
%% set_local_key(Key, Value, State) -> State.
%% set_local_keys(Keys, Values, State) -> State.
%% get_local_key(Key, State) -> Value | nil.
%%  Set variable values in the local environment. Variables are not
%%  cleared when their value is set to 'nil' as this would remove the
%%  local variable.

set_local_name(Name, Val, St) ->
    set_local_key(atom_to_binary(Name, latin1), Val, St).

set_local_key(Key, Val, #luerl{tabs=Ts0,env=Env}=St) ->
    Ts1 = set_local_key_env(Key, Val, Ts0, Env),
    St#luerl{tabs=Ts1}.

set_local_name_env(Name, Val, Ts, Env) ->
    set_local_key_env(atom_to_binary(Name, latin1), Val, Ts, Env).

set_local_key_env(K, Val, Ts, [#tref{i=E}|_]) ->
    Store = fun (#table{t=T}=Tab) -> Tab#table{t=orddict:store(K, Val, T)} end,
    ?UPD_TABLE(E, Store, Ts).

set_local_keys(Ks, Vals, #luerl{tabs=Ts0,env=[#tref{i=E}|_]}=St) ->
    Store = fun (#table{t=T}=Tab) ->
		    Tab#table{t=set_local_keys_tab(Ks, Vals, T)} end,
    Ts1 = ?UPD_TABLE(E, Store, Ts0),
    St#luerl{tabs=Ts1}.

set_local_keys_tab([K|Ks], [Val|Vals], T0) ->
    T1 = orddict:store(K, Val, T0),
    set_local_keys_tab(Ks, Vals, T1);
set_local_keys_tab([K|Ks], [], T0) ->
    T1 = orddict:store(K, nil, T0),		%Default value nil
    set_local_keys_tab(Ks, [], T1);
set_local_keys_tab([], _, T) -> T.		%Ignore extra values

get_local_key(Key, #luerl{tabs=Ts,env=[#tref{i=E}|_]}) ->
    #table{t=Tab} = ?GET_TABLE(E, Ts),
    case orddict:find(Key, Tab) of
	{ok,Val} -> Val;
	error -> nil
    end.

%% set_name(Name, Val, State) -> State.
%% set_key(Key, Value, State) -> State.
%% set_key_env(Key, Value, Tables, Env) -> Tables.
%% get_name(Name, State) -> Val.
%% get_key(Key, State) -> Value | nil.
%% get_key_env(Key, Tables, Env) -> Value | nil.
%%  Set/get variable values in the environment tables. Variables are
%%  not cleared when their value is set to 'nil' as this would move
%%  them in the environment stack.

set_name(Name, Val, St) ->
    set_key(atom_to_binary(Name, latin1), Val, St).

set_name_env(Name, Val, Ts, Env) ->
    set_key_env(atom_to_binary(Name, latin1), Val, Ts, Env).

set_key(K, Val, #luerl{tabs=Ts0,env=Env}=St) ->
    Ts1 = set_key_env(K, Val, Ts0, Env),
    St#luerl{tabs=Ts1}.

set_key_env(K, Val, Ts, [#tref{i=_G}]) ->	%Top table _G
    Store = fun (#table{t=T}=Tab) ->
		    Tab#table{t=orddict:store(K, Val, T)} end,
    ?UPD_TABLE(_G, Store, Ts);
set_key_env(K, Val, Ts, [#tref{i=E}|Es]) ->
    #table{t=Tab} = ?GET_TABLE(E, Ts),		%Find the table
    case orddict:is_key(K, Tab) of
	true ->
	    Store = fun (#table{t=T}=Tab0) ->
			    Tab0#table{t=orddict:store(K, Val, T)} end,
	    ?UPD_TABLE(E, Store, Ts);
	false -> set_key_env(K, Val, Ts, Es)
    end.

get_name(Name, St) -> get_key(atom_to_binary(Name, latin1), St).

get_key(K, #luerl{tabs=Ts,env=Env}) ->
    get_key_env(K, Ts, Env).

get_key_env(K, Ts, [#tref{i=E}|Es]) ->
    #table{t=Tab} = ?GET_TABLE(E, Ts),		%Get environment table
    case orddict:find(K, Tab) of		%Check if variable in the env
	{ok,Val} -> Val;
	error -> get_key_env(K, Ts, Es)
    end;
get_key_env(_, _, []) -> nil.			%The default value

%% chunk(Stats, State) -> {Return,State}.

chunk(Stats, St0) ->
    {Ret,St1} = function_block(fun (S) -> {[],stats(Stats, S)} end, St0),
    %% Should do GC here.
    {Ret,St1}.

%% funchunk(Function, State) -> {Return,State}.

funchunk({functiondef,_Line,_Name,_Pars,Body}, St0) ->
    {Ret,St1} = function_block(fun (S) -> {[],stats(Body, S)} end, St0),
    %% Should do GC here.
    {Ret,St1};

funchunk({functiondef,_Line,_Pars,Body}, St0) ->
    {Ret,St1} = function_block(fun (S) -> {[],stats(Body, S)} end, St0),
    %% Should do GC here.
    {Ret,St1}.

funchunk(Func, St0, _Pars) ->           %Todo: Parameters.
    funchunk(Func, St0).                %Note: from ERLANG. And the functiondef
                                        %is a wrap around ALL chunks except
                                        %those that already were functions.


%% block(Stats, State) -> State.
%%  Evaluate statements in a block. The with_block function requires
%%  that its action returns a result, which is irrelevant here.

block([], St) -> St;				%Empty block, do nothing
block(Stats, St0) ->
    Do = fun (S) -> {[],stats(Stats, S)} end,
    {_,St1} = with_block(Do, St0),
    St1.

%% with_block(Do, State) -> {Return,State}.
%% A block creates a new local environment which we would like to
%% remove afterwards. We can only do this if there are no local
%% functions defined within this block or sub-blocks. The 'locf' field
%% is set to 'true' when this occurs.

with_block(Do, St0) ->
    Locf0 = St0#luerl.locf,			%"Global" locf value
    {T,St1} = alloc_env(St0),			%Allocate the local table
    St2 = push_env(T, St1),			%Put it in the environment
    {Ret,St3} = Do(St2#luerl{locf=false}),	%Do its thing
    Locf1 = St3#luerl.locf,			%"Local" locf value
    St4  = case Locf1 of			%Check if we can free table
	       true -> pop_env(St3);
	       false -> pop_env(free_table(T, St3))
	   end,
    {Ret,St4#luerl{locf=Locf1 or Locf0}}.

%% stats(Stats, State) -> State.

stats([S|Ss], St0) ->
    St1 = stat(S, St0),
    stats(Ss, St1);
stats([], St) -> St.

%% stat(Stat, State) -> State.

stat({';',_}, St) -> St;			%A no-op
stat({assign,_,Vs,Es}, St) ->
     assign(Vs, Es, St);
stat({return,L,Es}, #luerl{tag=Tag}=St0) ->
    {Vals,St1} = explist(Es, St0),
    throw({return,L,Tag,Vals,St1});
stat({label,_,_}, _) ->				%Not implemented yet
    lua_error({undefined_op,label});
stat({break,L}, #luerl{tag=T}=St) ->
    throw({break,L,T,St});			%Easier match with explicit tag
stat({goto,_,_}, _) ->				%Not implemented yet
    lua_error({undefined_op,goto});
stat({block,_,B}, St) ->
    block(B, St);
stat({functiondef,L,Fname,Ps,B}, St) ->
    St1 = set_var(Fname, {function,L,St#luerl.env,Ps,B}, St),
    St1#luerl{locf=true};
stat({'while',_,Exp,Body}, St) ->
    do_while(Exp, Body, St);
stat({repeat,_,Body,Exp}, St) ->
    do_repeat(Body, Exp, St);
stat({'if',_,Tests,Else}, St) ->
    do_if(Tests, Else, St);
stat({for,Line,V,I,L,S,B}, St) ->
    do_numfor(Line, V, I, L, S, B, St);
stat({for,Line,V,I,L,B}, St) ->
    do_numfor(Line, V, I, L, {'NUMBER',Line,1.0}, B, St);
stat({for,Line,Ns,Gen,B}, St) ->
    do_genfor(Line, Ns, Gen, B, St);
stat({local,Decl}, St) ->
    %% io:format("sl: ~p\n", [Decl]),
    local(Decl, St);
stat(P, St0) ->
    %% These are just function calls here.
    {_,St1} = prefixexp(P, St0),		%Drop return value
    St1.

assign(Ns, Es, St0) ->
    {Vals,St1} = explist(Es, St0),
    assign_loop(Ns, Vals, St1).

assign_loop([Pre|Pres], [E|Es], St0) ->
    St1 = set_var(Pre, E, St0),
    assign_loop(Pres, Es, St1);
assign_loop([Pre|Pres], [], St0) ->		%Set remaining to nil
    St1 = set_var(Pre, nil, St0),
    assign_loop(Pres, [], St1);
assign_loop([], _, St) -> St.

%% set_var(PrefixExp, Val, State) -> State.
%%  Step down the prefixexp sequence evaluating as we go, stop at the
%%  end and return a key and a table where to put data. We can reuse
%%  much of the prefixexp code but must have our own thing at the end.

set_var({'.',_,Exp,Rest}, Val, St0) ->
    {[Next|_],St1} = prefixexp_first(Exp, St0),
    var_rest(Rest, Val, Next, St1);
set_var({'NAME',_,Name}, Val, St) ->
    set_name(Name, Val, St).
    
var_rest({'.',_,Exp,Rest}, Val, SoFar, St0) ->
    {[Next|_],St1} = prefixexp_element(Exp, SoFar, St0),
    var_rest(Rest, Val, Next, St1);
var_rest(Exp, Val, SoFar, St) ->
    var_last(Exp, Val, SoFar, St).

var_last({'NAME',_,N}, Val, SoFar, St) ->
    set_table_name(N, Val, SoFar, St);
var_last({key_field,_,Exp}, Val, SoFar, St0) ->
    {[Key|_],St1} = exp(Exp, St0),
    set_table_key(Key, Val, SoFar, St1);
var_last({method,_,{'NAME',_,N}}, {function,L,Env,Pars,B}, SoFar, St) ->
    %% Method a function, make a "method" by adding self parameter.
    set_table_name(N, {function,L,Env,[{'NAME',L,self}|Pars],B},
		   SoFar, St).

%% do_while(TestExp, Body, State) -> State.

do_while(Exp, Body, St0) ->
    While = fun (St) -> while_loop(Exp, Body, St) end,
    {_,St1} = loop_block(While, St0),
    St1.

while_loop(Exp, Body, St0) ->
    {Test,St1} = exp(Exp, St0),
    case is_true(Test) of
       true ->
	    St2 = block(Body, St1),
	    while_loop(Exp, Body, St2);
	false -> {[],St1}
    end.

%% do_repeat(Body, TestExp, State) -> State.

do_repeat(Body, Exp, St0) ->
    RepeatBody = fun (S0) ->			%Combine body with test
			 S1 = stats(Body, S0),
			 exp(Exp, S1)
		 end,
    Repeat = fun (St) -> repeat_loop(RepeatBody, St) end,
    {_,St1} = loop_block(Repeat, St0),		%element(2, ...)
    St1.

repeat_loop(Body, St0) ->
    {Ret,St1} = with_block(Body, St0),
    case is_true(Ret) of
	true -> {[],St1};
	false -> repeat_loop(Body, St1)
    end.

%% loop_block(DoLoop, State) -> State.
%%  The top level block to run loops in. Catch breaks here. Stack
%%  needs to be reset/unwound when we catch a break.

loop_block(Do, St) ->
    Block = fun (St0) ->
		    Tag = St0#luerl.tag,
		    try Do(St0)
		    catch
			throw:{break,_,Tag,St1} ->
			    %% Unwind the stack and freeing tables.
			    Old = St0#luerl.env,
			    St2 = unwind_stack(St1#luerl.env, Old, St1),
			    {[],St2}
		    end
	    end,
    with_block(Block, St).

%% do_if(Tests, Else, State) -> State.

do_if(Tests, Else, St0) ->
    %% io:format("di: ~p\n", [{Tests,Else}]),
    if_tests(Tests, Else, St0).

if_tests([{Exp,Block}|Ts], Else, St0) ->
    {[Test|_],St1} = exp(Exp, St0),		%What about the environment
    if Test =:= false; Test =:= nil ->		%Test failed, try again
	    if_tests(Ts, Else, St1);
       true ->					%Test succeeded, do block
	    block(Block, St1)
    end;
if_tests([], Else, St0) ->
    block(Else, St0).

%% do_numfor(Line, Var, Init, Limit, Step, Block, State) -> State.

do_numfor(_, {'NAME',_,Name}, Init, Limit, Step, Block, St0) ->
    NumFor = fun (St) -> numeric_for(Name, Init, Limit, Step, Block, St) end,
    {_,St1} = loop_block(NumFor, St0),
    St1.

numeric_for(Name, Init, Limit, Step, Block, St) ->
    %% Create a local block to run the whole for loop.
    Do = fun (St0) ->
		 {[I0,L0,S0],St1} = explist([Init,Limit,Step], St0),
		 I1 = luerl_lib:tonumber(I0),
		 L1 = luerl_lib:tonumber(L0),
		 S1 = luerl_lib:tonumber(S0),
		 if (I1 == nil) or (L1 == nil) or (S1 == nil) ->
			 badarg_error(for, [I0,L0,S0]);
		    true ->
			 numfor_loop(Name, I1, L1, S1, Block, St1)
		 end
	 end,
    with_block(Do, St).

numfor_loop(Name, I, L, S, B, St0)
  when S > 0, I =< L ; S =< 0, I >= L ->
    St1 = set_local_name(Name, I, St0),
    %% Create a local block for each iteration of the loop.
    St2 = block(B, St1),
    numfor_loop(Name, I+S, L, S, B, St2);
numfor_loop(_, _, _, _, _, St) -> {[],St}.	%We're done

%% do_genfor(Line, Names, Exps, Block, State) -> State.

do_genfor(_, Names, Exps, Block, St0) ->
    GenFor = fun (St) -> generic_for(Names, Exps, Block, St) end,
    {_,St1} = loop_block(GenFor, St0),
    St1.

generic_for(Names, Exps, Block, St) ->
    %% Create a local block to run the whole for loop.
    Do = fun (St0) ->
		 {Rets,St1} = explist(Exps, St0),
		 case Rets of			%Get 3 values!
		     [F] -> S = nil, Var = nil;
		     [F,S] -> Var = nil;
		     [F,S,Var|_] -> ok
		 end,
		 genfor_loop(Names, F, S, Var, Block, St1)
	 end,
    with_block(Do, St).

genfor_loop(Names, F, S, Var, Block, St0) ->
    {Vals,St1} = functioncall(F, [S,Var], St0),
    case is_true(Vals) of
	true ->	    				%We go on
	    St2 = assign_local_loop(Names, Vals, St1),
	    %% Create a local block for each iteration of the loop.
	    St3 = block(Block, St2),
	    genfor_loop(Names, F, S, hd(Vals), Block, St3);
	false -> {[],St1}			%Done
    end.

local({functiondef,L,{'NAME',_,Name},Ps,B}, #luerl{tabs=Ts0,env=Env}=St) ->
    %% Set name separately first so recursive call finds right Name.
    Ts1 = set_local_name_env(Name, nil, Ts0, Env),
    Ts2 = set_local_name_env(Name, {function,L,Env,Ps,B}, Ts1, Env),
    St#luerl{tabs=Ts2,locf=true};
local({assign,_,Ns,Es}, St0) ->
    {Vals,St1} = explist(Es, St0),
    assign_local_loop(Ns, Vals, St1).

assign_local_loop(Ns, Vals, St) ->
    Ts = assign_local_loop(Ns, Vals, St#luerl.tabs, St#luerl.env),
    St#luerl{tabs=Ts}.

assign_local_loop([{'NAME',_,V}|Ns], [Val|Vals], Ts0, Env) ->
    Ts1 = set_local_name_env(V, Val, Ts0, Env),
    assign_local_loop(Ns, Vals, Ts1, Env);
assign_local_loop([{'NAME',_,V}|Ns], [], Ts0, Env) ->
    Ts1 = set_local_name_env(V, nil, Ts0, Env),
    assign_local_loop(Ns, [], Ts1, Env);
assign_local_loop([], _, Ts, _) -> Ts.

%% explist([Exp], State) -> {[Val],State}.
%% Evaluate a list of expressions returning a list of values. If the
%% last expression returns more than one value then these are appended
%% to the returned list.

explist([E], St) -> exp(E, St);			%Appended values to output
explist([E|Es], St0) ->
    %% io:format("el: ~p\n", [E]),
    {[Val|_],St1} = exp(E, St0),		%Only take the first value
    {Vals,St2} = explist(Es, St1),
    {[Val|Vals],St2};
explist([], St) -> {[],St}.

%% exp(Exp, State) -> {Vals,State}.
%% Function calls can affect the state. Return a list of values!

exp({nil,_}, St) -> {[nil],St};
exp({false,_}, St) -> {[false],St};
exp({true,_}, St) -> {[true],St};
exp({'NUMBER',_,N}, St) -> {[N],St};
exp({'STRING',_,S}, St) -> {[S],St};
exp({'...',_}, St) ->				%Get '...', error if undefined
    case get_local_key('...', St) of
	nil -> illegal_val_error('...');
	Val -> {Val,St}
    end;
exp({functiondef,L,Ps,B}, St) ->
    {[{function,L,St#luerl.env,Ps,B}],St#luerl{locf=true}};
exp({table,_,Fs}, St0) ->
    {Ts,St1} = tableconstructor(Fs, St0),
    {T,St2} = alloc_table(Ts, St1),
    {[T],St2};
%% 'and' and 'or' short-circuit so need special handling.
exp({op,_,'and',L0,R0}, St0) ->
    {[L1|_],St1} = exp(L0, St0),
    if ?IS_TRUE(L1) ->
	    {[R1|_],St2} = exp(R0, St1),
	    {[R1],St2};
       true -> {[L1],St1}
    end;
exp({op,_,'or',L0,R0}, St0) ->
    {[L1|_],St1} = exp(L0, St0),
    if ?IS_TRUE(L1) -> {[L1],St1};
	true ->
	    {[R1|_],St2} = exp(R0, St1),
	    {[R1],St2}
    end;
%% All the other operators are strict.
exp({op,_,Op,L0,R0}, St0) ->
    {[L1|_],St1} = exp(L0, St0),
    {[R1|_],St2} = exp(R0, St1),
    op(Op, L1, R1, St2);
exp({op,_,Op,A0}, St0) ->
    {[A1|_],St1} = exp(A0, St0),
    op(Op, A1, St1);
exp(E, St) ->
    prefixexp(E, St).

%% prefixexp(PrefixExp, State) -> {[Vals],State}.
%% Step down the prefixexp sequence evaluating as we go.

prefixexp({'.',_,Exp,Rest}, St0) ->
    {[Next|_],St1} = prefixexp_first(Exp, St0),
    prefixexp_rest(Rest, Next, St1);
prefixexp(P, St) -> prefixexp_first(P, St).

prefixexp_first({'NAME',_,N}, St) -> {[get_name(N, St)],St};
prefixexp_first({single,_,E}, St0) ->		%Guaranteed only one value
    %% io:format("pf: ~p\n", [E]),
    {[R|_],St1} = exp(E, St0),
    {[R],St1}.

prefixexp_rest({'.',_,Exp,Rest}, SoFar, St0) ->
    {[Next|_],St1} = prefixexp_element(Exp, SoFar, St0),
    prefixexp_rest(Rest, Next, St1);
prefixexp_rest(Exp, SoFar, St) ->
    prefixexp_element(Exp, SoFar, St).

prefixexp_element({functioncall,_,Args0}, SoFar, St0) ->
    {Args1,St1} = explist(Args0, St0),
    functioncall(SoFar, Args1, St1);
prefixexp_element({'NAME',_,N}, SoFar, St0) ->
    {V,St1} = get_table_name(N, SoFar, St0),
    {[V],St1};
prefixexp_element({key_field,_,Exp}, SoFar, St0) ->
    {[Key|_],St1} = exp(Exp, St0),
    {V,St2} = get_table_key(Key, SoFar, St1),
    {[V],St2};
prefixexp_element({method,_,{'NAME',_,N},Args0}, SoFar, St0) ->
    {Func,St1} = get_table_name(N, SoFar, St0),
    {Args1,St2} = explist(Args0, St1),
    functioncall(Func, [SoFar|Args1], St2).

functioncall({function,_,Env,Ps,B}, Args, St0) ->
    Env0 = St0#luerl.env,			%Caller's environment
    St1 = St0#luerl{env=Env},			%Set function's environment
    Do = fun (S0) ->
		 %% Use local assign to put argument into environment.
		 S1 = assign_par_loop(Ps, Args, S0),
		 {[],stats(B, S1)}
	 end,
    {Ret,St2} = function_block(Do, St1),
    St3 = St2#luerl{env=Env0},			%Restore caller's environment
    {Ret,St3};
functioncall({function,Fun}, Args, St) when is_function(Fun) ->
    Fun(Args, St);
functioncall({userdata,Fun}, Args, St) when is_function(Fun) ->
    Fun(Args, St);
functioncall(Func, As, St) ->
    %% io:format("fc: ~p\n", [{Func,As}]),
    case getmetamethod(Func, <<"__call">>, St) of
	nil -> badarg_error(Func, As);
	Meta -> functioncall(Meta, As, St)
    end.

%% assign_par_loop(Names, Vals, State) -> State.
%% Could probably merge this and assign_local_loop.

assign_par_loop(Ns, Vals, St) ->
    Ts = assign_par_loop(Ns, Vals, St#luerl.tabs, St#luerl.env),
    St#luerl{tabs=Ts}.

assign_par_loop([{'NAME',_,V}|Ns], [Val|Vals], Ts0, Env) ->
    Ts1 = set_local_name_env(V, Val, Ts0, Env),
    assign_par_loop(Ns, Vals, Ts1, Env);
assign_par_loop([{'NAME',_,V}|Ns], [], Ts0, Env) ->
    Ts1 = set_local_name_env(V, nil, Ts0, Env),
    assign_par_loop(Ns, [], Ts1, Env);
assign_par_loop([{'...',_}], Vs, Ts, Env) ->
    set_local_key_env('...', Vs, Ts, Env);
assign_par_loop([], _, Ts, _) -> Ts.

%% function_block(Do, State) -> {Return,State}.
%%  The top level block in which to evaluate functions run loops
%%  in. Catch returns and breaks here; breaks are errors as they
%%  should have been caught already. Stack needs to be reset/unwound
%%  when we catch a break.

function_block(Do, St) ->
    Block = fun (St0) ->
		    Tag = St0#luerl.tag,
		    try Do(St0)
		    catch
			throw:{return,_,Tag,Ret,St1} ->
			    %% Unwind the stack and freeing tables.
			    Old = St0#luerl.env,
			    St2 = unwind_stack(St1#luerl.env, Old, St1),
			    {Ret,St2};
			throw:{break,L,Tag,_} ->
			    lua_error({illegal_op,L,break})
		    end
	    end,
    with_block(Block, St).

%% unwind_stack(From, To, State) -> State.
%%  If locf else is false then we can unwind env stack freeing tables
%%  as we go, otherwise if locf is true we can not do this.

%% unwind_stack(_, To, St) -> St#luerl{env=To};	%For testing
unwind_stack(_, _, #luerl{locf=true}=St) -> St;
unwind_stack(From, [Top|_]=To, #luerl{tabs=Ts0,free=Ns0}=St) ->
    {Ts1,Ns1} = unwind_stack(From, Top, Ts0, Ns0),
    St#luerl{tabs=Ts1,free=Ns1,env=To}.

unwind_stack([Top|_], Top, Ts, Ns) -> {Ts,Ns};	%Done!
unwind_stack([#tref{i=N}|From], Top, Ts0, Ns) ->
    Ts1 = ?DEL_TABLE(N, Ts0),
    %% io:format("us: ~p\n", [N]),
    unwind_stack(From, Top, Ts1, [N|Ns]).

%% tableconstructor(Fields, State) -> {TableData,State}.

tableconstructor(Fs, St0) ->
    Fun = fun ({exp_field,_,Ve}, {I,S0}) ->
		  {[V|_],S1} = exp(Ve, S0),
		  {{I,V},{I+1,S1}};
	      ({name_field,_,{'NAME',_,N},Ve}, {I,S0}) ->
		  {[V|_],S1} = exp(Ve, S0),
		  K = atom_to_binary(N, latin1),
		  {{K,V},{I,S1}};
	      ({key_field,_,Ke,Ve}, {I,S0}) ->
		  {[K|_],S1} = exp(Ke, S0),
		  {[V|_],S2} = exp(Ve, S1),
		  {{K,V},{I,S2}}
	  end,
    {T,{_,St1}} = lists:mapfoldl(Fun, {1.0,St0}, Fs),
    {orddict:from_list(T),St1}.

%% op(Op, Arg, State) -> {[Ret],State}.
%% op(Op, Arg1, Arg2, State) -> {[Ret],State}.
%% The built-in operators.

op('-', A, St) ->
    numeric_op('-', A, <<"__unm">>, fun (N) -> -N end, St);
op('not', A, St) -> {[not ?IS_TRUE(A)],St};
%% op('not', false, St) -> {[true],St};
%% op('not', nil, St) -> {[true],St};
%% op('not', _, St) -> {[false],St};		%Everything else is false
op('#', B, St) when is_binary(B) -> {[float(byte_size(B))],St};
op('#', #tref{}=T, St) ->
    luerl_table:length(T, St);
op(Op, A, _) -> badarg_error(Op, [A]).

%% Numeric operators.

op('+', A1, A2, St) ->
    numeric_op('+', A1, A2, <<"__add">>, fun (N1,N2) -> N1+N2 end, St);
op('-', A1, A2, St) ->
    numeric_op('-', A1, A2, <<"__sub">>, fun (N1,N2) -> N1-N2 end, St);
op('*', A1, A2, St) ->
    numeric_op('*', A1, A2, <<"__mul">>, fun (N1,N2) -> N1*N2 end, St);
op('/', A1, A2, St) ->
    numeric_op('/', A1, A2, <<"__div">>, fun (N1,N2) -> N1/N2 end, St);
op('%', A1, A2, St) ->
    numeric_op('%', A1, A2, <<"__mod">>,
	       fun (N1,N2) -> N1 - round(N1/N2 - 0.5)*N2 end, St);
op('^', A1, A2, St) ->
    numeric_op('^', A1, A2, <<"__pow">>,
	       fun (N1,N2) -> math:pow(N1, N2) end, St);
%% Relational operators, getting close.
op('==', A1, A2, St) -> eq_op('==', A1, A2, St);
op('~=', A1, A2, St) -> neq_op('~=', A1, A2, St);
op('<=', A1, A2, St) -> le_op('<=', A1, A2, St);
op('>=', A1, A2, St) -> le_op('>=', A2, A1, St);
op('<', A1, A2, St) -> lt_op('<', A1, A2, St);
op('>', A1, A2, St) -> lt_op('>', A2, A1, St);
%% String operator.
op('..', A1, A2, St) ->
    B1 = luerl_lib:tostring(A1),
    B2 = luerl_lib:tostring(A2),
    if B1 =/= nil, B2 =/= nil -> {[<< B1/binary,B2/binary >>],St};
       true ->
	    Meta = getmetamethod(A1, A2, <<"__concat">>, St),
	    functioncall(Meta, [A1,A2], St)
    end;
%% Bad args here.
op(Op, A1, A2, _) -> badarg_error(Op, [A1,A2]).

%% numeric_op(Op, Arg, Event, Raw, State) -> {[Ret],State}.
%% numeric_op(Op, Arg, Arg, Event, Raw, State) -> {[Ret],State}.
%% eq_op(Op, Arg, Arg, State) -> {[Ret],State}.
%% neq_op(Op, Arg, Arg, State) -> {[Ret],State}.
%% lt_op(Op, Arg, Arg, State) -> {[Ret],State}.
%% le_op(Op, Arg, Arg, State) -> {[Ret],State}.
%%  Straigt out of the reference manual.

numeric_op(_Op, O, E, Raw, St0) ->
    N = luerl_lib:tonumber(O),
    if is_number(N) -> {[Raw(N)],St0};
       true ->
	    Meta = getmetamethod(O, E, St0),
	    {Ret,St1} = functioncall(Meta, [O], St0),
	    {[is_true(Ret)],St1}
    end.

numeric_op(_Op, O1, O2, E, Raw, St0) ->
    N1 = luerl_lib:tonumber(O1),
    N2 = luerl_lib:tonumber(O2),
    if is_number(N1), is_number(N2) -> {[Raw(N1, N2)],St0};
       true ->
	    Meta = getmetamethod(O1, O2, E, St0),
	    {Ret,St1} = functioncall(Meta, [O1,O2], St0),
	    {[is_true(Ret)],St1}
    end.

eq_op(_Op, O1, O2, St) when O1 =:= O2 -> {[true],St};
eq_op(_Op, O1, O2, St0) ->
    {Ret,St1} = eq_meta(O1, O2, St0),
    {[is_true(Ret)],St1}.

neq_op(_Op, O1, O2, St) when O1 =:= O2 -> {[false],St};
neq_op(_Op, O1, O2, St0) ->
    {Ret,St1} = eq_meta(O1, O2, St0),
    {[not is_true(Ret)],St1}.

eq_meta(O1, O2, St0) ->
    case getmetamethod(O1, <<"__eq">>, St0) of
	nil -> {[false],St0};			%Tweren't no method
	Meta ->
	    case getmetamethod(O2, <<"__eq">>, St0) of
		Meta ->				%Must be the same method
		    functioncall(Meta, [O1,O2], St0);
		_ -> {[false],St0}
	    end
    end.

lt_op(_Op, O1, O2, St) when is_number(O1), is_number(O2) -> {[O1 < O2],St};
lt_op(_Op, O1, O2, St) when is_binary(O1), is_binary(O2) -> {[O1 < O2],St};
lt_op(_Op, O1, O2, St0) ->
    Meta = getmetamethod(O1, O2, <<"__lt">>, St0),
    {Ret,St1} = functioncall(Meta, [O1,O2], St0),
    {[is_true(Ret)],St1}.

le_op(_Op, O1, O2, St) when is_number(O1), is_number(O2) -> {[O1 =< O2],St};
le_op(_Op, O1, O2, St) when is_binary(O1), is_binary(O2) -> {[O1 =< O2],St};
le_op(_Op, O1, O2, St0) ->
    case getmetamethod(O1, O2, <<"__le">>, St0) of
	Meta when Meta =/= nil ->
	    {Ret,St1} = functioncall(Meta, [O1,O2], St0),
	    {[is_true(Ret)],St1};
	nil ->
	    %% Try for not (Op2 < Op1) instead.
	    Meta = getmetamethod(O1, O2, <<"__lt">>, St0),
	    {Ret,St1} = functioncall(Meta, [O2,O1], St0),
	    {[not is_true(Ret)],St1}
    end.

%% getmetamethod(Object1, Object2, Event, State) -> Metod | nil.
%% getmetamethod(Object, Event, State) -> Method | nil.
%% Get the metamethod for object(s).

getmetamethod(O1, O2, E, St) ->
    case getmetamethod(O1, E, St) of
	nil -> getmetamethod(O2, E, St);
	M -> M
    end.

getmetamethod(#tref{i=N}, E, #luerl{tabs=Ts}) ->
    #table{m=Meta} = ?GET_TABLE(N, Ts),
    getmetamethod_tab(Meta, E, Ts);
getmetamethod({userdata,_}, E, #luerl{tabs=Ts,meta=Meta}) ->
    getmetamethod_tab(Meta#meta.userdata, E, Ts);
getmetamethod(S, E, #luerl{tabs=Ts,meta=Meta}) when is_binary(S) ->
    getmetamethod_tab(Meta#meta.string, E, Ts);
getmetamethod(N, E, #luerl{tabs=Ts,meta=Meta}) when is_number(N) ->
    getmetamethod_tab(Meta#meta.number, E, Ts);
getmetamethod(_, _, _) -> nil.			%Other types have no metatables

getmetamethod_tab(#tref{i=M}, E, Ts) ->
    #table{t=Mtab} = ?GET_TABLE(M, Ts),
    case orddict:find(E, Mtab) of
	{ok,Mm} -> Mm;
	error -> nil
    end;
getmetamethod_tab(_, _, _) -> nil.		%Other types have no metatables

%% is_true(Rets) -> boolean()>

is_true([nil|_]) -> false;
is_true([false|_]) -> false;
is_true([_|_]) -> true;
is_true([]) -> false.

first_value([V|_]) -> V;
first_value([]) -> nil.

badarg_error(What, Args) ->
    lua_error({badarg,What,Args}).

illegal_val_error(Val) ->
    lua_error({illegal_val,Val}).

%% gc(State) -> State.
%% The garbage collector. Its main job is to reclaim unused tables. It
%% is a mark/sweep collector which passes over all objects and marks
%% tables which it has seen. All unseen tables are then freed and
%% their index added to the free list.

gc(#luerl{tabs=Ts0,meta=Meta,free=Free0,env=Env}=St) ->
    Root = [Meta#meta.number,Meta#meta.string,Meta#meta.userdata|Env],
    Seen = mark(Root, [], [], Ts0),
    %% io:format("gc: ~p\n", [Seen]),
    %% Free unseen tables and add freed to free list.
    Ts1 = ?FILTER_TABLES(fun (K, _) -> ordsets:is_element(K, Seen) end, Ts0),
    Free1 = ?FOLD_TABLES(fun (K, _, F) ->
				 case ordsets:is_element(K, Seen) of
				     true -> F;
				     false -> [K|F]
				 end
			 end, Free0, Ts0),
    St#luerl{tabs=Ts1,free=Free1}.

%% mark(ToDo, MoreTodo, Seen, Tabs) -> Seen.
%% Scan over all live objects and mark seen tables by adding them to
%% the seen list.

mark([{in_table,_}=T|Todo], More, Seen, Ts) ->
    %%io:format("gc: ~p\n", [T]),
    mark(Todo, More, Seen, Ts);
mark([#tref{i=T}|Todo], More, Seen0, Ts) ->
    case ordsets:is_element(T, Seen0) of
	true ->					%Already done
	    mark(Todo, More, Seen0, Ts);
	false ->				%Must do it
	    Seen1 = ordsets:add_element(T, Seen0),
	    #table{t=Tab,m=Meta} = ?GET_TABLE(T, Ts),
	    %% Have to be careful where add Tab and Meta as Tab is a
	    %% [{Key,Val}] and Meta is a nil|#tref{i=M}. We want lists.
	    mark([Meta|Todo], [[{in_table,T}],Tab,[{in_table,-T}]|More], Seen1, Ts)
    end;
mark([{function,_,Env,_,_}|Todo], More, Seen, Ts) ->
    mark(Todo, [Env|More], Seen, Ts);
%% Catch these as they would match table key-value pair.
mark([{function,_}|Todo], More, Seen, Ts) ->
    mark(Todo, More, Seen, Ts);
mark([#thread{}|Todo], More, Seen, Ts) ->
    mark(Todo, More, Seen, Ts);
mark([#userdata{m=Meta}|Todo], More, Seen, Ts) ->
    mark([Meta|Todo], More, Seen, Ts);
mark([{K,V}|Todo], More, Seen, Ts) ->		%Table key-value pair
    %%io:format("mt: ~p\n", [{K,V}]),
    mark([K,V|Todo], More, Seen, Ts);
mark([_|Todo], More, Seen, Ts) ->		%Can ignore everything else
    mark(Todo, More, Seen, Ts);
mark([], [M|More], Seen, Ts) ->
    mark(M, More, Seen, Ts);
mark([], [], Seen, _) -> Seen.

%% emul(Code, Stack, State) -> {Stack,State}.

%% Stack fiddling.
emul([{push,X}|Code], Sp, St) ->
    emul(Code, [X|Sp], St);
emul([pop|Code], [_|Sp], St) ->
    emul(Code, Sp, St);
emul([swap|Code], [S1,S2|Sp], St) ->
    emul(Code, [S2,S1|Sp], St);
%% Accessing tables/environment.
emul([get_env|Code], [Key|Sp], St) ->
    io:format("ge: ~p\n", [[Key|Sp]]),
    Val = get_key(Key, St),
    emul(Code, [Val|Sp], St);
emul([set_env|Code], [Key,Val|Sp], St) ->
    io:format("se: ~p\n", [[Key,Val|Sp]]),
    Val = set_key(Key, Val, St),
    emul(Code, [Val|Sp], St);
emul([get_key|Code], [Key,Tab|Sp], St0) ->
    {Val,St1} = get_table_key(Key, Tab, St0),
    emul(Code, [Val|Sp], St1);
emul([set_key|Code], [Key,Tab,Val|Sp], St0) ->
    io:format("sk: ~p\n", [[Key,Tab,Val|Sp]]),
    St1 = set_table_key(Key, Val, Tab, St0),
    emul(Code, Sp, St1);
emul([get_local|Code], [Key|Sp], St) ->
    Val = get_local_key(Key, St),
    emul(Code, [Val|Sp], St);
emul([set_local|Code], [Key,Val|Sp], St0) ->
    St1 = set_local_key(Key, Val, St0),
    emul(Code, Sp, St1);
%% Expressions
emul([{build_tab,0}|Code], Sp, St0) ->
    {Tab,St1} = alloc_table([], St0),
    emul(Code, [Tab|Sp], St1);
%% Function calls/return values.
emul([{build_args,0}|Code], Sp, St) ->
    emul(Code, [[]|Sp], St);
emul([{build_args,1}|Code], [A1|Sp], St) ->
    emul(Code, [[A1]|Sp], St);
emul([{build_args,2}|Code], [A2,A1|Sp], St) ->
    emul(Code, [[A1,A2]|Sp], St);
emul([{build_args,3}|Code], [A3,A2,A1|Sp], St) ->
    emul(Code, [[A1,A2,A3]|Sp], St);
emul([{build_args,N}|Code], Sp0, St) ->
    {As,Sp1} = revn(N, Sp0),
    emul(Code, [As|Sp1], St);
emul([call|Code], [As,Func|Sp], St0) ->
    io:format("ca: ~p\n", [[As,Func|Sp]]),
    {Ret,St1} = functioncall(Func, As, St0),
    emul(Code, [Ret|Sp], St1);
emul([first_value|Code], [[V|_]|Sp], St) ->
    emul(Code, [V|Sp], St);
%% Local environment shuffling.
emul([push_env|Code], Sp, St0) ->
    {T,St1} = alloc_env(St0),
    St2 = push_env(T, St1),
    emul(Code, [T|Sp], St2);
emul([pop_env|Code], [_|Sp], St0) ->
    St1 = pop_env(St0),
    emul(Code, Sp, St1);
emul([pop_env_free|Code], [T|Sp], St0) ->
    St1 = pop_env(free_table(T, St0)),
    emul(Code, Sp, St1);
emul([], Sp, St) -> {Sp,St}.

revn(N, L) -> revn(N, L, []).

revn(0, Es, Acc) -> {Acc,Es};
revn(N, [E|Es], Acc) -> revn(N-1, Es, [E|Acc]).