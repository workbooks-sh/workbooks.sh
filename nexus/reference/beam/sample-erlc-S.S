{module, spikesrc}.  %% version = 0

{exports, [{add,2},{loop,1},{module_info,0},{module_info,1}]}.

{attributes, []}.

{labels, 10}.


{function, add, 2, 2}.
  {label,1}.
    {line,[{location,"spikesrc.erl",3}]}.
    {func_info,{atom,spikesrc},{atom,add},2}.
  {label,2}.
    {gc_bif,'+',{f,0},2,[{x,0},{x,1}],{x,0}}.
    return.


{function, loop, 1, 4}.
  {label,3}.
    {line,[{location,"spikesrc.erl",4}]}.
    {func_info,{atom,spikesrc},{atom,loop},1}.
  {label,4}.
    {test,is_ge,{f,5},[{integer,0},{x,0}]}.
    {move,{integer,0},{x,0}}.
    return.
  {label,5}.
    {line,[{location,"spikesrc.erl",5}]}.
    {gc_bif,'-',
            {f,0},
            1,
            [{tr,{x,0},
                 {t_union,{t_atom,any},
                          {t_list,any,any},
                          {t_number,{0,'+inf'}},
                          {t_tuple,0,false,#{}},
                          other}},
             {integer,1}],
            {x,1}}.
    {allocate,1,2}.
    {move,{x,0},{y,0}}.
    {move,{x,1},{x,0}}.
    {call,1,{f,4}}. % loop/1
    {'%',{var_info,{x,0},[{type,{t_number,{0,'+inf'}}}]}}.
    {gc_bif,'+',
            {f,0},
            1,
            [{tr,{y,0},{t_number,{0,'+inf'}}},
             {tr,{x,0},{t_number,{0,'+inf'}}}],
            {x,0}}.
    {deallocate,1}.
    return.


{function, module_info, 0, 7}.
  {label,6}.
    {line,[]}.
    {func_info,{atom,spikesrc},{atom,module_info},0}.
  {label,7}.
    {move,{atom,spikesrc},{x,0}}.
    {call_ext_only,1,{extfunc,erlang,get_module_info,1}}.


{function, module_info, 1, 9}.
  {label,8}.
    {line,[]}.
    {func_info,{atom,spikesrc},{atom,module_info},1}.
  {label,9}.
    {move,{x,0},{x,1}}.
    {move,{atom,spikesrc},{x,0}}.
    {call_ext_only,2,{extfunc,erlang,get_module_info,2}}.
