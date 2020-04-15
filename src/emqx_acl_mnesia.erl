%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_acl_mnesia).

-include("emqx_auth_mnesia.hrl").

-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/logger.hrl").

%% ACL Callbacks
-export([ init/0
        , register_metrics/0
        , check_acl/5
        , description/0
        ]).

init() ->
    ok = ekka_mnesia:create_table(emqx_acl, [
            {type, bag},
            {disc_copies, [node()]},
            {attributes, record_info(fields, emqx_acl)}]),
    ok = ekka_mnesia:copy_table(emqx_user, disc_copies).

-spec(register_metrics() -> ok).
register_metrics() ->
    lists:foreach(fun emqx_metrics:new/1, ?ACL_METRICS).

check_acl(ClientInfo, PubSub, Topic, NoMatchAction, #{key_as := KeyAs}) ->
    Key = case KeyAs of
        username -> #{username := Username} = ClientInfo, Username; 
        clientid -> #{clientid := ClientID} = ClientInfo, ClientID
    end,
    case do_check_acl(Key, PubSub, Topic, NoMatchAction) of
        ok -> emqx_metrics:inc(?ACL_METRICS(ignore)), ok;
        {stop, allow} -> emqx_metrics:inc(?ACL_METRICS(allow)), {stop, allow};
        {stop, deny} -> emqx_metrics:inc(?ACL_METRICS(deny)), {stop, deny}
    end.

description() -> "Acl with Mnesia".

%%--------------------------------------------------------------------
%% Internal functions
%%-------------------------------------------------------------------

do_check_acl(Key, PubSub, Topic, _NoMatchAction) ->
    case emqx_acl_mnesia_cli:lookup_acl(Key) of
        [] -> ok;
        UserAcl ->
            case match(PubSub, Topic, UserAcl) of
                allow -> {stop, allow};
                nomatch -> {stop, deny}
            end;
        {error, Reason} ->
            ?LOG(error, "[Mnesia] do_check_acl error: ~p~n", [Reason]),
            ok
    end.

match(_PubSub, _Topic, []) ->
    nomatch;
match(PubSub, Topic, [ {emqx_acl, _Login, ACLTopic, Action} | UserAcl]) ->
    case match_actions(PubSub, Action) andalso match_topic(Topic, ACLTopic) of
        true -> allow;
        false -> match(PubSub, Topic, UserAcl)
    end.

match_topic(Topic, ACLTopic) when is_binary(Topic) ->
    emqx_topic:match(Topic, ACLTopic).

match_actions(_, <<"pubsub">>) -> true;
match_actions(subscribe, <<"sub">>) -> true;
match_actions(publish, <<"pub">>) -> true;
match_actions(_, _) -> false.