%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ Federation.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2013 GoPivotal, Inc.  All rights reserved.
%%

-module(rabbit_federation_upstream).

-include("rabbit_federation.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

-export([set_for/1, for/1, for/2, params_to_string/1, to_params/2]).
%% For testing
-export([from_set/2, remove_credentials/1]).

-import(rabbit_misc, [pget/2, pget/3]).
-import(rabbit_federation_util, [name/1, vhost/1, r/1]).

%%----------------------------------------------------------------------------

set_for(XorQ) -> rabbit_policy:get(<<"federation-upstream-set">>, XorQ).

for(XorQ) ->
    case set_for(XorQ) of
        undefined   -> [];
        UpstreamSet -> from_set(UpstreamSet, XorQ)
    end.

for(XorQ, UpstreamName) ->
    case set_for(XorQ) of
        undefined   -> [];
        UpstreamSet -> from_set(UpstreamSet, XorQ, UpstreamName)
    end.

params_table(SafeURI, Params, XorQ) ->
    Key = case XorQ of
              #exchange{} -> <<"exchange">>;
              #amqqueue{} -> <<"queue">>
          end,
    [{<<"uri">>,          longstr, SafeURI},
     {<<"virtual_host">>, longstr, vhost(Params)},
     {Key,                longstr, name(XorQ)}].

params_to_string(#upstream_params{safe_uri = SafeURI,
                                  x_or_q   = XorQ}) ->
    print("~s on ~s", [rabbit_misc:rs(r(XorQ)), SafeURI]).

remove_credentials(URI) ->
    Props = uri_parser:parse(binary_to_list(URI),
                             [{host, undefined}, {path, undefined},
                              {port, undefined}, {'query', []}]),
    PortPart = case pget(port, Props) of
                   undefined -> "";
                   Port      -> rabbit_misc:format(":~B", [Port])
               end,
    PGet = fun(K, P) -> case pget(K, P) of undefined -> ""; R -> R end end,
    list_to_binary(
      rabbit_misc:format(
        "~s://~s~s~s", [pget(scheme, Props), PGet(host, Props),
                        PortPart,            PGet(path, Props)])).

to_params(Upstream = #upstream{uris = URIs}, XorQ) ->
    random:seed(now()),
    URI = lists:nth(random:uniform(length(URIs)), URIs),
    {ok, Params} = amqp_uri:parse(binary_to_list(URI), vhost(XorQ)),
    XorQ1 = with_name(Upstream, vhost(Params), XorQ),
    SafeURI = remove_credentials(URI),
    #upstream_params{params   = Params,
                     uri      = URI,
                     x_or_q   = XorQ1,
                     safe_uri = SafeURI,
                     table    = params_table(SafeURI, Params, XorQ)}.

print(Fmt, Args) -> iolist_to_binary(io_lib:format(Fmt, Args)).

from_set(SetName, XorQ, UpstName) ->
    rabbit_federation_util:find_upstreams(UpstName, from_set(SetName, XorQ)).

from_set(<<"all">>, XorQ) ->
    Connections = rabbit_runtime_parameters:list(
                    vhost(XorQ), <<"federation-upstream">>),
    Set = [[{<<"upstream">>, pget(name, C)}] || C <- Connections],
    from_set_contents(Set, XorQ);

from_set(SetName, XorQ) ->
    case rabbit_runtime_parameters:value(
           vhost(XorQ), <<"federation-upstream-set">>, SetName) of
        not_found -> [];
        Set       -> from_set_contents(Set, XorQ)
    end.

from_set_contents(Set, XorQ) ->
    Results = [from_set_element(P, XorQ) || P <- Set],
    [R || R <- Results, R =/= not_found].

from_set_element(UpstreamSetElem, XorQ) ->
    Name = bget(upstream, UpstreamSetElem, []),
    case rabbit_runtime_parameters:value(
           vhost(XorQ), <<"federation-upstream">>, Name) of
        not_found  -> not_found;
        Upstream   -> from_props_connection(
                        UpstreamSetElem, Name, Upstream, XorQ)
    end.

from_props_connection(U, Name, C, XorQ) ->
    URIParam = bget(uri, U, C),
    URIs = case URIParam of
               B when is_binary(B) -> [B];
               L when is_list(L)   -> L
           end,
    #upstream{uris            = URIs,
              exchange_name   = bget(exchange,          U, C, name(XorQ)),
              queue_name      = bget(queue,             U, C, name(XorQ)),
              prefetch_count  = bget('prefetch-count',  U, C, ?DEFAULT_PREFETCH),
              reconnect_delay = bget('reconnect-delay', U, C, 1),
              max_hops        = bget('max-hops',        U, C, 1),
              expires         = bget(expires,           U, C, none),
              message_ttl     = bget('message-ttl',     U, C, none),
              trust_user_id   = bget('trust-user-id',   U, C, false),
              ack_mode        = list_to_atom(
                                  binary_to_list(
                                    bget('ack-mode', U, C, <<"on-confirm">>))),
              ha_policy       = bget('ha-policy',       U, C, none),
              name            = Name}.

%%----------------------------------------------------------------------------

bget(K, L1, L2) -> bget(K, L1, L2, undefined).

bget(K0, L1, L2, D) ->
    K = a2b(K0),
    case pget(K, L1, undefined) of
        undefined -> pget(K, L2, D);
        Result    -> Result
    end.

a2b(A) -> list_to_binary(atom_to_list(A)).

with_name(#upstream{exchange_name = XNameBin}, VHostBin, X = #exchange{}) ->
    X#exchange{name = rabbit_misc:r(VHostBin, exchange, XNameBin)};

with_name(#upstream{queue_name = QNameBin}, VHostBin, Q = #amqqueue{}) ->
    Q#amqqueue{name = rabbit_misc:r(VHostBin, queue, QNameBin)}.
