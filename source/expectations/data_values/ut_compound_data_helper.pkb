create or replace package body ut_compound_data_helper is
  /*
  utPLSQL - Version 3
  Copyright 2016 - 2018 utPLSQL Project

  Licensed under the Apache License, Version 2.0 (the "License"):
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
  */

  g_user_defined_type pls_integer := dbms_sql.user_defined_type;
  gc_diff_count       integer;
  
  function get_column_info_xml(a_column_details ut_key_anyval_pair) return xmltype is
    l_result varchar2(4000);
    l_res xmltype;
    l_data ut_data_value := a_column_details.value;
    l_key varchar2(4000) := ut_utils.xmlgen_escaped_string(a_column_details.KEY);
  begin
    l_result := '<'||l_key||' xml_valid_name="'||l_key||'">';
    if l_data is of(ut_data_value_xmltype) then
      l_result := l_result || (treat(l_data as ut_data_value_xmltype).to_string);
    else
      l_result := l_result || ut_utils.xmlgen_escaped_string((treat(l_data as ut_data_value_varchar2).data_value));
    end if;
    
    l_result := l_result ||'</'||l_key||'>';  
    return xmltype(l_result);
  end;
  
  function get_columns_filter(
    a_exclude_xpath varchar2, a_include_xpath varchar2,
    a_table_alias varchar2 := 'ucd', a_column_alias varchar2 := 'item_data'
  ) return varchar2 is
    l_filter varchar2(32767);
    l_source_column varchar2(500) := a_table_alias||'.'||a_column_alias;
  begin
    -- this SQL statement is constructed in a way that we always get the same number and ordering of substitution variables
    -- That is, we always get: l_exclude_xpath, l_include_xpath
    --   regardless if the variables are NULL (not to be used) or NOT NULL and will be used for filtering
    if a_exclude_xpath is null and a_include_xpath is null then
      l_filter := ':l_exclude_xpath, :l_include_xpath, '||l_source_column||' as '||a_column_alias;
    elsif a_exclude_xpath is not null and a_include_xpath is null then
      l_filter := 'deletexml( '||l_source_column||', :l_exclude_xpath ) as '||a_column_alias||', :l_include_xpath';
    elsif a_exclude_xpath is null and a_include_xpath is not null then
      l_filter := ':l_exclude_xpath, extract( '||l_source_column||', :l_include_xpath ) as '||a_column_alias;
    elsif a_exclude_xpath is not null and a_include_xpath is not null then
      l_filter := 'extract( deletexml( '||l_source_column||', :l_exclude_xpath ), :l_include_xpath ) as '||a_column_alias;
    end if;
    return l_filter;
  end;
 
  /**
  * Current get column filter shaving off ROW tag during extract, this not working well with include and XMLTABLE option
  * so when there is extract we artificially inject removed tag
  **/
  function get_columns_row_filter(
    a_exclude_xpath varchar2, a_include_xpath varchar2,
    a_table_alias varchar2 := 'ucd', a_column_alias varchar2 := 'item_data'
  ) return varchar2 is
    l_filter varchar2(32767);
    l_source_column varchar2(500) := a_table_alias||'.'||a_column_alias;
  begin
    -- this SQL statement is constructed in a way that we always get the same number and ordering of substitution variables
    -- That is, we always get: l_exclude_xpath, l_include_xpath
    --   regardless if the variables are NULL (not to be used) or NOT NULL and will be used for filtering
    if a_exclude_xpath is null and a_include_xpath is null then
      l_filter := ':l_exclude_xpath, :l_include_xpath, '||l_source_column||' as '||a_column_alias;
    elsif a_exclude_xpath is not null and a_include_xpath is null then
      l_filter := 'deletexml( '||l_source_column||', :l_exclude_xpath ) as '||a_column_alias||', :l_include_xpath';
    elsif a_exclude_xpath is null and a_include_xpath is not null then
      l_filter := ':l_exclude_xpath, xmlelement("ROW",extract( '||l_source_column||', :l_include_xpath )) as '||a_column_alias;
    elsif a_exclude_xpath is not null and a_include_xpath is not null then
      l_filter := 'xmlelement("ROW",extract( deletexml( '||l_source_column||', :l_exclude_xpath ), :l_include_xpath )) as '||a_column_alias;
    end if;
    return l_filter;
  end;

  function get_columns_diff(
    a_expected xmltype, a_actual xmltype, a_exclude_xpath varchar2, a_include_xpath varchar2
  ) return tt_column_diffs is
    l_column_filter  varchar2(32767);
    l_sql            varchar2(32767);
    l_results        tt_column_diffs;
  begin
    l_column_filter := get_columns_row_filter(a_exclude_xpath, a_include_xpath);
    --CARDINALITY hints added to address issue: https://github.com/utPLSQL/utPLSQL/issues/752
    l_sql := q'[
      with
        expected_cols as ( select :a_expected as item_data from dual ),
        actual_cols as ( select :a_actual as item_data from dual ),
        expected_cols_info as (
          select e.*,
                 replace(expected_type,'VARCHAR2','CHAR') expected_type_compare
            from (
                  select /*+ CARDINALITY(xt 100) */
                         rownum expected_pos,
                         xt.name expected_name,
                         xt.type expected_type
                    from (select ]'||l_column_filter||q'[ from expected_cols ucd) x,
                         xmltable(
                           '/ROW/*'
                           passing x.item_data
                           columns
                             name     varchar2(4000)  PATH '@xml_valid_name',
                             type     varchar2(4000) PATH '/'
                         ) xt
                 ) e
        ),
        actual_cols_info as (
          select a.*,
                 replace(actual_type,'VARCHAR2','CHAR') actual_type_compare
            from (select /*+ CARDINALITY(xt 100) */
                         rownum actual_pos,
                         xt.name actual_name,
                         xt.type actual_type
                    from (select ]'||l_column_filter||q'[ from actual_cols ucd) x,
                         xmltable('/ROW/*'
                           passing x.item_data
                           columns
                             name     varchar2(4000)  path '@xml_valid_name',
                             type      varchar2(4000) path '/'
                         ) xt
                 ) a
        ),
        joined_cols as (
         select e.*, a.*,
                row_number() over(partition by case when actual_pos + expected_pos is not null then 1 end order by actual_pos) a_pos_nn,
                row_number() over(partition by case when actual_pos + expected_pos is not null then 1 end order by expected_pos) e_pos_nn
           from expected_cols_info e
           full outer join actual_cols_info a on e.expected_name = a.actual_name
      )
      select case
               when expected_pos is null and actual_pos is not null then '+'
               when expected_pos is not null and actual_pos is null then '-'
               when expected_type_compare != actual_type_compare then 't'
               else 'p'
             end as diff_type,
             expected_name, expected_type, expected_pos,
             actual_name, actual_type, actual_pos
        from joined_cols
             --column is unexpected (extra) or missing
       where actual_pos is null or expected_pos is null
          --column type is not matching (except CHAR/VARCHAR2)
          or actual_type_compare != expected_type_compare
          --column position is not matching (both when excluded extra/missing columns as well as when they are included)
          or (a_pos_nn != e_pos_nn and expected_pos != actual_pos)
       order by expected_pos, actual_pos]';
    execute immediate l_sql
      bulk collect into l_results
      using a_expected, a_actual, a_exclude_xpath, a_include_xpath, a_exclude_xpath, a_include_xpath;

    return l_results;
  end;
  
  function get_pk_value (a_join_by_xpath varchar2,a_item_data xmltype) return clob is
    l_pk_value clob;
  begin
    select replace((extract(a_item_data,a_join_by_xpath).getclobval()),chr(10)) into l_pk_value from dual;    
    return l_pk_value; 
  end;

  function get_rows_diff_by_sql(
    a_expected_dataset_guid raw, a_actual_dataset_guid raw, a_diff_id raw,
    a_max_rows integer, a_exclude_xpath varchar2, a_include_xpath varchar2,
    a_join_by_xpath varchar2
  ) return tt_row_diffs is
    
    l_act_col_filter varchar2(32767);
    l_exp_col_filter varchar2(32767);
    l_results       tt_row_diffs;
  begin
    l_act_col_filter := get_columns_row_filter(a_exclude_xpath,a_include_xpath,'ucd','act_item_data');
    l_exp_col_filter := get_columns_row_filter(a_exclude_xpath,a_include_xpath,'ucd','exp_item_data');
    
    execute immediate q'[with diff_info as 
    ( select act_data_id, exp_data_id,]'
      ||l_act_col_filter||','|| l_exp_col_filter||q'[, :join_by join_by, item_no
      from ut_compound_data_diff_tmp  ucd
      where diff_id = :diff_id ),
    exp as (
    select exp_item_data, exp_data_id, item_no rn,rownum col_no,
      nvl2(exp_item_data,ut3.ut_compound_data_helper.get_pk_value(i.join_by,exp_item_data),null) pk_value,
      s.column_value col, s.column_value.getRootElement() col_name, s.column_value.getclobval() col_val
    from diff_info i,
    table( xmlsequence( extract(i.exp_item_data,'/*/*') ) ) s
    where i.exp_data_id = :self_guid),
    act as (
    select act_item_data, act_data_id, item_no rn, rownum col_no,
      nvl2(act_item_data,ut3.ut_compound_data_helper.get_pk_value(i.join_by,act_item_data),null) pk_value,
      s.column_value col, s.column_value.getRootElement() col_name, s.column_value.getclobval() col_val
    from diff_info i,
    table( xmlsequence( extract(i.act_item_data,'/*/*') ) ) s
    where i.act_data_id = :other_guid)
    select rn, diff_type, xmlserialize(content data_item no indent) diffed_row, pk_value pk_value
    from (
      select nvl(exp.rn, act.rn) rn, nvl(exp.pk_value, act.pk_value) pk_value, exp.col  exp_item, act.col  act_item        
      from exp join act
      on exp.rn = act.rn and exp.col_name = act.col_name
      where dbms_lob.compare(exp.col_val, act.col_val) != 0)
    unpivot ( data_item for diff_type in (exp_item as 'Expected:', act_item as 'Actual:') )
    union all
    select item_no as rn, case when exp_data_id is null then 'Extra' else 'Missing' end as diff_type,
      xmlserialize(content (case when exp_data_id is null then act_item_data else exp_item_data end) no indent) diffed_row,
      nvl2(i.join_by,ut3.ut_compound_data_helper.get_pk_value(i.join_by,case when exp_data_id is null then act_item_data else exp_item_data end),null) pk_value
   from diff_info i
   where act_data_id is null or exp_data_id is null]'
   bulk collect into l_results
    using a_exclude_xpath,a_include_xpath,
          a_exclude_xpath,a_include_xpath,
          a_join_by_xpath, a_diff_id, a_expected_dataset_guid,a_actual_dataset_guid;
        
    return l_results;
  end;
    
  function get_rows_diff(
    a_expected_dataset_guid raw, a_actual_dataset_guid raw, a_diff_id raw,
    a_max_rows integer, a_exclude_xpath varchar2, a_include_xpath varchar2,
    a_join_by_xpath varchar2
  ) return tt_row_diffs is
    l_column_filter varchar2(32767);
    l_results       tt_row_diffs;
  begin
    l_column_filter := get_columns_row_filter(a_exclude_xpath,a_include_xpath);
    
   /**
    * Since its unordered search we cannot select max rows from diffs as we miss some comparision records
    * We will restrict output on higher level of select
    * NO_MERGE hint was introduced to prevent optimizer from merging views and rewriting query which in some cases
    * lead to second value being null depend on execution plan that been chosen
    **/
    execute immediate q'[
    with diff_info as (select item_hash,pk_hash,duplicate_no from ut_compound_data_diff_tmp ucdc where diff_id = :diff_guid)
      select rn,diff_type,diffed_row,pk_value from
      (
      select 
      diff_type, diffed_row, 
      dense_rank() over (order by case when diff_type in ('Extra','Missing') then diff_type end,
                                  case when diff_type in ('Actual','Expected') then pk_hash end,
                                  case when diff_type in ('Extra','Missing') then pk_hash end,
                                  case when diff_type in ('Actual','Expected') then diff_type end) rn,
      pk_value, pk_hash 
      from
      (
      select diff_type,diffed_row,pk_hash,pk_value from
        (select diff_type,data_item diffed_row,pk_hash,pk_value
         from
          (select /*+NO_MERGE*/ nvl(exp.pk_hash, act.pk_hash) pk_hash,nvl(exp.pk_value, act.pk_value) pk_value,
             xmlserialize(content exp.row_data no indent)  exp_item,
             xmlserialize(content act.row_data no indent)  act_item
             from 
              (select ucd.*
               from 
                (select ucd.column_value row_data,
                 r.item_hash row_hash,
                 r.pk_hash ,
                 r.duplicate_no,
                 ucd.column_value.getclobval() col_val,
                 ucd.column_value.getRootElement() col_name,
                 ut_compound_data_helper.get_pk_value(:join_xpath,r.item_data) pk_value
                 from 
                  (select ]'||l_column_filter||q'[, ucd.item_no, ucd.item_hash, i.pk_hash, i.duplicate_no
                   from ut_compound_data_tmp ucd,
                   diff_info i
                   where ucd.data_id = :self_guid
                   and ucd.item_hash = i.item_hash
                  ) r,
                  table( xmlsequence( extract(r.item_data,'/*/*') ) ) ucd
                ) ucd
              ) exp
              join (
                select ucd.*
                from 
                 (select ucd.column_value row_data,
                  r.item_hash row_hash,
                  r.pk_hash ,
                  r.duplicate_no,
                  ucd.column_value.getclobval() col_val,
                  ucd.column_value.getRootElement() col_name,
                  ut_compound_data_helper.get_pk_value(:join_xpath,r.item_data) pk_value
                  from 
                   (select ]'||l_column_filter||q'[, ucd.item_no, ucd.item_hash, i.pk_hash, i.duplicate_no
                    from ut_compound_data_tmp ucd,
                    diff_info i
                    where ucd.data_id = :other_guid
                    and ucd.item_hash = i.item_hash
                   ) r,
                   table( xmlsequence( extract(r.item_data,'/*/*') ) ) ucd
                 ) ucd
              )  act
              on exp.pk_hash = act.pk_hash  and exp.col_name = act.col_name
              and exp.duplicate_no = act.duplicate_no
             where dbms_lob.compare(exp.col_val, act.col_val) != 0
              )
            unpivot ( data_item for diff_type in (exp_item as 'Expected:', act_item as 'Actual:') )
         )
      union all       
      select case when exp.pk_hash is null then 'Extra' else 'Missing' end as diff_type,
             xmlserialize(content nvl(exp.item_data, act.item_data) no indent) diffed_row,
             coalesce(exp.pk_hash,act.pk_hash) pk_hash,
             coalesce(exp.pk_value,act.pk_value) pk_value
        from (select extract(deletexml(ucd.item_data, :join_by),'/*/*') item_data,i.pk_hash,
                ut_compound_data_helper.get_pk_value(:join_by,item_data) pk_value
                from ut_compound_data_tmp ucd,
                diff_info i
               where ucd.data_id = :self_guid
                 and ucd.item_hash = i.item_hash
             ) exp
        full outer join (
              select extract(deletexml(ucd.item_data, :join_by),'/*/*') item_data,i.pk_hash,
                ut_compound_data_helper.get_pk_value(:join_by,item_data) pk_value
                from ut_compound_data_tmp ucd,
                diff_info i
               where ucd.data_id = :other_guid
                 and ucd.item_hash = i.item_hash
             )act
          on exp.pk_hash = act.pk_hash
       where exp.pk_hash is null or act.pk_hash is null
       ) 
       ) where  rn <= :max_rows
       order by rn, pk_hash, diff_type
      ]'
    bulk collect into l_results
    using a_diff_id,
    a_join_by_xpath,
    a_exclude_xpath, a_include_xpath, a_expected_dataset_guid,
    a_join_by_xpath,
    a_exclude_xpath, a_include_xpath, a_actual_dataset_guid,
    a_join_by_xpath,a_join_by_xpath,a_expected_dataset_guid,a_join_by_xpath,a_join_by_xpath, a_actual_dataset_guid,
    a_max_rows;
        
    return l_results;
  end;

  function get_rows_diff(
    a_expected_dataset_guid raw, a_actual_dataset_guid raw, a_diff_id raw,
    a_max_rows integer, a_exclude_xpath varchar2, a_include_xpath varchar2
  ) return tt_row_diffs is
    l_column_filter varchar2(32767);
    l_results       tt_row_diffs;
  begin
    l_column_filter := get_columns_filter(a_exclude_xpath,a_include_xpath);
    execute immediate q'[
      with
        diff_info as ( select item_no 
                       from 
                         (select item_no from ut_compound_data_diff_tmp ucdc where diff_id = :diff_guid order by item_no asc) 
                       where rownum <= :max_rows)
      select *
        from (select rn, diff_type, xmlserialize(content data_item no indent) diffed_row, null pk_value
                from (select nvl(exp.rn, act.rn) rn,
                             xmlagg(exp.col order by exp.col_no) exp_item,
                             xmlagg(act.col order by act.col_no) act_item
                        from (select r.item_no as rn, rownum col_no, s.column_value col,
                                     s.column_value.getRootElement() col_name,
                                     s.column_value.getclobval() col_val
                                from (select ]'||l_column_filter||q'[, ucd.item_no, ucd.item_data item_data_no_filter
                                        from ut_compound_data_tmp ucd,
                                        diff_info i
                                       where ucd.data_id = :self_guid
                                       and ucd.item_no = i.item_no
                                    ) r,
                                     table( xmlsequence( extract(r.item_data,'/*/*') ) ) s
                             ) exp
                        join (
                              select item_no as rn, rownum col_no, s.column_value col,
                                     s.column_value.getRootElement() col_name,
                                     s.column_value.getclobval() col_val
                                from (select ]'||l_column_filter||q'[, ucd.item_no, ucd.item_data item_data_no_filter
                                        from ut_compound_data_tmp ucd,
                                        diff_info i
                                       where ucd.data_id = :other_guid
                                       and ucd.item_no = i.item_no
                                    ) r,
                                     table( xmlsequence( extract(r.item_data,'/*/*') ) ) s
                              ) act
                          on exp.rn = act.rn and exp.col_name = act.col_name
                       where dbms_lob.compare(exp.col_val, act.col_val) != 0
                       group by exp.rn, act.rn
                     )
              unpivot ( data_item for diff_type in (exp_item as 'Expected:', act_item as 'Actual:') )
             )
      union all
      select nvl(exp.item_no, act.item_no) rn,
             case when exp.item_no is null then 'Extra:' else 'Missing:' end as diff_type,
             xmlserialize(content nvl(exp.item_data, act.item_data) no indent) diffed_row,
             null pk_value
        from (select ucd.item_no, extract(ucd.item_data,'/*/*') item_data
                from ut_compound_data_tmp ucd
               where ucd.data_id = :self_guid
                 and ucd.item_no in (select i.item_no from diff_info i)
             ) exp
        full outer join (
              select ucd.item_no, extract(ucd.item_data,'/*/*') item_data
                from ut_compound_data_tmp ucd
               where ucd.data_id = :other_guid
                 and ucd.item_no in (select i.item_no from diff_info i)
             )act
          on exp.item_no = act.item_no
       where exp.item_no is null or act.item_no is null
      order by 1, 2]'
    bulk collect into l_results
    using a_diff_id, a_max_rows,
    a_exclude_xpath, a_include_xpath, a_expected_dataset_guid,
    a_exclude_xpath, a_include_xpath, a_actual_dataset_guid,
    a_expected_dataset_guid, a_actual_dataset_guid;
    return l_results;
  end;

  function get_rows_diff_unordered(
    a_expected_dataset_guid raw, a_actual_dataset_guid raw, a_diff_id raw,
    a_max_rows integer, a_exclude_xpath varchar2, a_include_xpath varchar2
  ) return tt_row_diffs is
    l_column_filter varchar2(32767);
    l_results       tt_row_diffs;
  begin
    l_column_filter := get_columns_filter(a_exclude_xpath,a_include_xpath);
    
    /**
    * Since its unordered search we cannot select max rows from diffs as we miss some comparision records
    * We will restrict output on higher level of select
    */    
    execute immediate q'[with
      diff_info as (select item_hash,duplicate_no from ut_compound_data_diff_tmp ucdc where diff_id = :diff_guid)
      select duplicate_no,
             diffed_type,
             diffed_row,
             null pk_value
      from
      (select  
        coalesce(exp.duplicate_no,act.duplicate_no) duplicate_no,
        case 
          when act.row_hash is null then 
            'Missing:'  
          else 'Extra:' 
        end diffed_type,
        case when exp.row_hash is null then 
          xmlserialize(content act.row_data no indent) 
        when act.row_hash is null then
          xmlserialize(content exp.row_data no indent) 
        end diffed_row
         from (select ucd.*
            from (select ucd.column_value row_data,
                    r.item_hash row_hash,
                    r.duplicate_no
                    from (select ]'||l_column_filter||q'[, ucd.item_no, i.item_hash, i.duplicate_no
                        from ut_compound_data_tmp ucd,
                        diff_info i
                        where ucd.data_id = :self_guid
                        and ucd.item_hash = i.item_hash
                        and ucd.duplicate_no = i.duplicate_no
                       ) r,
                  table( xmlsequence( extract(r.item_data,'/*') ) ) ucd
              ) ucd
          )  exp
      full outer join
        (select ucd.*
         from (select ucd.column_value row_data,
                      r.item_hash row_hash,
                      r.duplicate_no
                      from (select  ]'||l_column_filter||q'[, ucd.item_no, i.item_hash, i.duplicate_no
                     from ut_compound_data_tmp ucd,
                     diff_info i
                     where ucd.data_id = :other_guid
                     and ucd.item_hash = i.item_hash
                     and ucd.duplicate_no = i.duplicate_no
                     ) r,
               table( xmlsequence( extract(r.item_data,'/*') ) ) ucd
               ) ucd
       )  act
      on   exp.row_hash = act.row_hash
          and exp.duplicate_no = act.duplicate_no
      where exp.row_hash is null or act.row_hash is null 
      order by diffed_type, coalesce(exp.row_hash,act.row_hash), duplicate_no
      )
      where rownum < :max_rows ]'
    bulk collect into l_results
    using a_diff_id,
    a_exclude_xpath, a_include_xpath, a_expected_dataset_guid,
    a_exclude_xpath, a_include_xpath, a_actual_dataset_guid,
    a_max_rows;
    
    return l_results;

  end;
  
  function compare_type(a_join_by_xpath in varchar2,a_unordered boolean, a_is_sql_diffable integer := 0) return varchar2 is
    begin
      case 
        when a_is_sql_diffable = 1 then
         return gc_compare_sql;
        when a_join_by_xpath is not null then
          return gc_compare_join_by;
        when a_unordered then
          return gc_compare_unordered;
        else
          return gc_compare_normal;
        end case;
    end; 
  
  function get_rows_diff(
    a_expected_dataset_guid raw, a_actual_dataset_guid raw, a_diff_id raw,
    a_max_rows integer, a_exclude_xpath varchar2, a_include_xpath varchar2,
    a_join_by_xpath varchar2,a_unorderdered boolean, a_is_sql_diffable integer
  ) return tt_row_diffs is
        l_result tt_row_diffs := tt_row_diffs();
    l_compare_type  varchar2(10):= compare_type(a_join_by_xpath,a_unorderdered, a_is_sql_diffable);
  begin
    case 
      when l_compare_type = gc_compare_sql then
        l_result := get_rows_diff_by_sql(a_expected_dataset_guid, a_actual_dataset_guid, a_diff_id,
                                   a_max_rows, a_exclude_xpath, a_include_xpath ,a_join_by_xpath);                                  
      when l_compare_type = gc_compare_join_by then
        l_result := get_rows_diff(a_expected_dataset_guid, a_actual_dataset_guid, a_diff_id,
                                   a_max_rows, a_exclude_xpath, a_include_xpath ,a_join_by_xpath);
      when l_compare_type = gc_compare_unordered then 
        l_result := get_rows_diff_unordered(a_expected_dataset_guid, a_actual_dataset_guid, a_diff_id,
                                             a_max_rows, a_exclude_xpath, a_include_xpath);
      else
        l_result := get_rows_diff(a_expected_dataset_guid, a_actual_dataset_guid, a_diff_id,
                                   a_max_rows, a_exclude_xpath, a_include_xpath);
      end case;
      return l_result;
  end;

  function get_hash(a_data raw, a_hash_type binary_integer := dbms_crypto.hash_sh1) return t_hash is
  begin
    return dbms_crypto.hash(a_data, a_hash_type);
  end;

  function get_hash(a_data clob, a_hash_type binary_integer := dbms_crypto.hash_sh1) return t_hash is
  begin
    return dbms_crypto.hash(a_data, a_hash_type);
  end;

  function columns_hash(
    a_data_value_cursor ut_data_value_refcursor, a_exclude_xpath varchar2, a_include_xpath varchar2,
    a_hash_type binary_integer := dbms_crypto.hash_sh1
  ) return t_hash is
    l_cols_hash t_hash;
  begin      
    if not a_data_value_cursor.is_null then      
      execute immediate
      q'[select dbms_crypto.hash(replace(x.item_data.getclobval(),'>CHAR<','>VARCHAR2<'),]'||a_hash_type||') ' ||
      '  from ( select '||get_columns_filter(a_exclude_xpath, a_include_xpath)||
      '           from (select :columns_info as item_data from dual ) ucd' ||
      '  ) x'
      into l_cols_hash using a_exclude_xpath,a_include_xpath, a_data_value_cursor.columns_info;
    end if;
    return l_cols_hash;
  end;

  function is_pk_exists(a_expected_cursor xmltype,a_actual_cursor xmltype, a_exclude_xpath varchar2, a_include_xpath varchar2,a_join_by_xpath varchar2) 
  return tt_missing_pk is
    l_pk_xpath_tabs ut_varchar2_list := ut_varchar2_list();
    l_column_filter  varchar2(32767);
    l_no_missing_keys tt_missing_pk := tt_missing_pk();

  begin
    if a_join_by_xpath is not null then
      l_pk_xpath_tabs := ut_utils.string_to_table(a_join_by_xpath,'|');
      l_column_filter := get_columns_row_filter(a_exclude_xpath, a_include_xpath);
    
      execute immediate q'[
      with  xpaths_tab as (select column_value  xpath from table(:xpath_tabs)),
        expected_column_info as ( select :expected as item_data from dual ),
        actual_column_info as ( select :actual as item_data from dual ) 
        select  REGEXP_SUBSTR (xpath,'[^(/\*/)](.+)$'),diif_type from
        (
         (select xpath,'e' diif_type from xpaths_tab
         minus
         select xpath,'e' diif_type
         from   ( select ]'||l_column_filter||q'[ from expected_column_info ucd) x
         ,xpaths_tab
         where xmlexists (xpaths_tab.xpath passing x.item_data)
         )
         union all
         (select xpath,'a' diif_type from xpaths_tab
         minus
         select xpath,'a' diif_type
         from   ( select ]'||l_column_filter||q'[ from actual_column_info ucd) x
         ,xpaths_tab
         where xmlexists (xpaths_tab.xpath passing x.item_data)
         )       
         )]' bulk collect into l_no_missing_keys 
         using l_pk_xpath_tabs,a_expected_cursor,a_actual_cursor,
         a_exclude_xpath, a_include_xpath,
         a_exclude_xpath, a_include_xpath; 
    
    end if;
    
    return l_no_missing_keys;
  end;
   
  procedure update_row_and_pk_hash(a_self_data_id in raw, a_other_data_id in raw, a_exclude_xpath varchar2, 
                                   a_include_xpath varchar2, a_join_by_xpath varchar2) is
    l_ut_owner        varchar2(250) := ut_utils.ut_owner;
    l_column_filter   varchar2(32767);
    l_pk_hash_sql     varchar2(32767);
    
    function get_column_pk_hash(a_join_by_xpath varchar2) return varchar2 is
      l_column varchar2(32767);
    begin
      /* due to possibility of key being to columns we cannot use xmlextractvalue
         usage of xmlagg is possible however it greatly complicates code and performance is impacted.
         xpath to be looked at or regex
      */
      if a_join_by_xpath is not null then
        l_column :=  l_ut_owner ||'.ut_compound_data_helper.get_hash(extract(ucd.item_data,:join_by_xpath).GetClobVal()) pk_hash';
      else
        l_column := ':join_by_xpath pk_hash';
      end if;
      return l_column;
    end;  
  
  begin
    l_column_filter := ut_compound_data_helper.get_columns_filter(a_exclude_xpath, a_include_xpath);
    l_pk_hash_sql := get_column_pk_hash(a_join_by_xpath);
    
    --Use a item hash as pk hash for unordered     
    execute immediate 'merge into ' || l_ut_owner || '.ut_compound_data_tmp tgt
                       using (
                              select ucd_out.item_hash,
                                     ucd_out.pk_hash,
                                     ucd_out.item_no, 
                                     ucd_out.data_id,
                                     row_number() over (partition by ucd_out.pk_hash,ucd_out.item_hash,ucd_out.data_id order by 1,2) duplicate_no
                              from 
                              (
                              select '||l_ut_owner ||'.ut_compound_data_helper.get_hash(ucd.item_data.getclobval()) item_hash, 
                                      pk_hash, ucd.item_no, ucd.data_id
                              from
                              (
                              select '||l_column_filter||','||l_pk_hash_sql||', item_no, data_id
                              from  ' || l_ut_owner || q'[.ut_compound_data_tmp ucd
                              where data_id = :self_guid or data_id = :other_guid
                              ) ucd
                              )ucd_out
                       ) src
                       on (tgt.item_no = src.item_no and tgt.data_id = src.data_id)
                       when matched then update
                       set tgt.item_hash = src.item_hash,
                           tgt.pk_hash = src.pk_hash,
                           tgt.duplicate_no = src.duplicate_no]'
                       using a_exclude_xpath, a_include_xpath,a_join_by_xpath,a_self_data_id, a_other_data_id;    

  end;
   
  function get_unordered(a_owner in varchar2) return varchar2 is
    l_sql varchar2(32767);
  begin
    l_sql := 'with source_data as
                       ( select t.data_id,t.item_hash,t.duplicate_no,
                           pk_hash
                           from  ' || a_owner || '.ut_compound_data_tmp t
                           where data_id = :self_guid or data_id = :other_guid
                        )           
                       select distinct :diff_id,tmp.item_hash,tmp.pk_hash,tmp.duplicate_no
                       from(
                         (
                           select t.item_hash,t. duplicate_no,t.pk_hash
                           from  source_data t
                           where t.data_id = :self_guid
                           minus
                           select t.item_hash,t. duplicate_no,t.pk_hash
                           from  source_data t
                           where t.data_id = :other_guid
                         )
                           union all
                         (
                           select t.item_hash,t. duplicate_no,t.pk_hash
                           from  source_data t
                           where t.data_id = :other_guid
                           minus
                           select t.item_hash,t. duplicate_no,t.pk_hash
                           from  source_data t
                           where t.data_id = :self_guid
                        ))tmp';
    return l_sql;
  end;
 
  function get_inclusion_matcher_sql(a_owner in varchar2) return varchar2 is
    l_sql varchar2(32767);
  begin
    l_sql := 'with source_data as
                       ( select t.data_id,t.item_hash,t.duplicate_no,
                           pk_hash
                           from  ' || a_owner || '.ut_compound_data_tmp t
                           where data_id = :self_guid or data_id = :other_guid
                        )           
                       select distinct :diff_id,tmp.item_hash,tmp.pk_hash,tmp.duplicate_no
                       from( 
                         (
                           select t.item_hash,t. duplicate_no,t.pk_hash
                           from  source_data t
                           where t.data_id = :self_guid
                           minus
                           select t.item_hash,t. duplicate_no,t.pk_hash
                           from  source_data t
                           where t.data_id = :other_guid
                         )
                           union all
                         (
                           select t.item_hash,t. duplicate_no,t.pk_hash
                           from  source_data t,
                           source_data s
                           where t.data_id = :other_guid 
                           and s.data_id = :self_guid 
                           and t.pk_hash = s.pk_hash
                           and t.item_hash != s.item_hash
                         )
                        )
                        tmp';
    return l_sql;
  end;
   
   function get_not_inclusion_matcher_sql(a_owner in varchar2) return varchar2 is
    l_sql varchar2(32767);
  begin
    /* Self set does not contain any values from other set */
    l_sql := 'with source_data as
                       ( select t.data_id,t.item_hash,t.duplicate_no,
                           pk_hash
                           from  ' || a_owner || '.ut_compound_data_tmp t
                           where data_id = :self_guid or data_id = :other_guid
                        )           
                       select distinct :diff_id,tmp.item_hash,tmp.pk_hash,tmp.duplicate_no
                       from
                         (
                         select act.item_hash,act. duplicate_no,act.pk_hash
                         from  source_data act where act.data_id = :self_guid
                         and exists ( select 1
                                      from  source_data exp
                                      where exp.data_id = :other_guid
                                      and exp.item_hash = act.item_hash
                                     )
                        union all
                        select null,null,null
                        from dual where :other_guid = :self_guid
                        )
                        tmp';
    return l_sql;
  end;  
   
  -- TODO:Rebuild as the unordered can be done using join_by compare
  function get_refcursor_matcher_sql(a_owner in varchar2,a_inclusion_matcher boolean := false, a_negated_match boolean := false) return varchar2  is
    l_sql varchar2(32767);
  begin
    l_sql := 'insert into ' || a_owner || '.ut_compound_data_diff_tmp ( diff_id,item_hash,pk_hash,duplicate_no)'||chr(10);
    if a_inclusion_matcher and not(a_negated_match) then
      l_sql := l_sql || get_inclusion_matcher_sql(a_owner);
    elsif a_inclusion_matcher and a_negated_match then
      l_sql := l_sql || get_not_inclusion_matcher_sql(a_owner);
    elsif not(a_inclusion_matcher) then
      l_sql := l_sql || get_unordered(a_owner);
    end if;
    
    return l_sql;
  end;

  function generate_xmltab_stmt (a_column_info ut_varchar2_list) return clob is
    l_sql_stmt clob;
  begin    
    for i in 1..a_column_info.count loop
      l_sql_stmt := l_sql_stmt || case when l_sql_stmt is null then null else ',' end ||a_column_info(i)||q'[ varchar2(4000) PATH ']'||a_column_info(i)||q'[']';
    end loop;
    return l_sql_stmt;
  end;

  function generate_equal_sql (a_column_info ut_varchar2_list) return clob is
    l_sql_stmt clob;
  begin
    for i in 1..a_column_info.count loop
      l_sql_stmt := l_sql_stmt || case when l_sql_stmt is null then null else ' and ' end ||' a.'||a_column_info(i)||q'[ = ]'||' e.'||a_column_info(i);
    end loop;
    
    return l_sql_stmt;
  end;

  function generate_join_by_on_stmt (a_join_by_xpath_tab ut_varchar2_list) return clob is
      l_sql_stmt clob;
  begin      
    for i in (with  xpaths_tab as (select column_value  xpath from table(a_join_by_xpath_tab))
              select REGEXP_SUBSTR (xpath,'[^(/\*/)](.+)$') name
              from xpaths_tab)
    loop
      l_sql_stmt := l_sql_stmt || case when l_sql_stmt is null then null else ' and ' end ||' a.'||i.name||q'[ = ]'||' e.'||i.name;
    end loop;
    return l_sql_stmt;
  end;

  function generate_not_equal_sql (a_column_info ut_varchar2_list, a_join_by_xpath ut_varchar2_list) return clob is
    l_sql_stmt clob;
  begin 
    for i in (
    with  xpaths_tab as (select column_value  xpath from table(a_join_by_xpath)),
    pk_names as (select REGEXP_SUBSTR (xpath,'[^(/\*/)](.+)$') name
              from xpaths_tab)
     select /*+ CARDINALITY(xt 100) */
     column_value as name
     from table(a_column_info) xt
     where not exists (select 1 from pk_names p where lower(p.name) = lower(xt.column_value))
     )
    loop
      l_sql_stmt := l_sql_stmt || case when l_sql_stmt is null then null else ' or ' end ||' (decode(a.'||i.name||','||' e.'||i.name||',1,0) = 0)';
    end loop;
    return l_sql_stmt;
  end;  
  
  function gen_compare_sql(a_column_info xmltype, a_exclude_xpath varchar2, 
                                   a_include_xpath varchar2, a_join_by_xpath varchar2) return clob is
    l_compare_sql   clob;
    l_temp_string   varchar2(32767);
    
    l_pk_xpath_tabs  ut_varchar2_list := ut_varchar2_list();
    l_act_col_tab    ut_varchar2_list := ut_varchar2_list();
    
    l_ut_owner       varchar2(250) := ut_utils.ut_owner;
    l_xmltable_stmt  clob;
    l_where_stmt     clob;
    
    function get_columns_names (a_xpath_tab in ut_varchar2_list) return ut_varchar2_list is
      l_names_tab ut_varchar2_list := ut_varchar2_list();
    begin
      select REGEXP_SUBSTR (column_value,'[^(/\*/)](.+)$')
      bulk collect into l_names_tab
      from table(a_xpath_tab);    
      return l_names_tab;
    end;
 
    function get_columns_info (a_columns_info in xmltype) return ut_varchar2_list is
      l_columns_info ut_varchar2_list := ut_varchar2_list();
    begin
     select /*+ CARDINALITY(xt 100) */
     xt.name
     bulk collect into l_columns_info
     from (select a_column_info item_data from dual) x,
           xmltable(
           '/ROW/*'
           passing x.item_data
           columns
           name     varchar2(4000)  PATH '@xml_valid_name'
           ) xt;  
      return l_columns_info;
    end; 
   
  begin
    dbms_lob.createtemporary(l_compare_sql, true);
    
    --Check include and exclude columns and create an actual column list that have to be compared.
    --TODO :Reformat
    if a_include_xpath is null and a_exclude_xpath is null then
      l_act_col_tab := get_columns_info(a_column_info);
    elsif a_include_xpath is not null and a_exclude_xpath is null then
      l_act_col_tab := get_columns_names(ut_utils.string_to_table(a_include_xpath,'|'));
    elsif a_include_xpath is null and a_exclude_xpath is not null then
      l_act_col_tab := get_columns_info(a_column_info) multiset except get_columns_names(ut_utils.string_to_table(a_exclude_xpath,'|'));
    elsif a_include_xpath is not null and a_exclude_xpath is not null then
      l_act_col_tab := get_columns_names(ut_utils.string_to_table(a_include_xpath,'|')) multiset except get_columns_names(ut_utils.string_to_table(a_exclude_xpath,'|'));
    end if;
    
    l_pk_xpath_tabs := get_columns_names(ut_utils.string_to_table(a_join_by_xpath,'|'));   
    
    l_xmltable_stmt := generate_xmltab_stmt(l_act_col_tab);
    
    l_temp_string := q'[with exp as (select ucd.*,x.item_no,x.data_id from (select item_data,item_no,data_id from ]' || l_ut_owner || q'[.ut_compound_data_tmp where data_id = :self_guid) x,]'
                     ||q'[xmltable('/ROWSET/ROW' passing x.item_data columns ]';   
    ut_utils.append_to_clob(l_compare_sql, l_temp_string);   
    ut_utils.append_to_clob(l_compare_sql,l_xmltable_stmt);
    
    l_temp_string := q'[ ,item_data xmltype PATH '*' ) ucd),]'
                     ||q'[act as (select ucd.*, x.item_no,x.data_id from (select item_data,item_no,data_id from ]' || l_ut_owner || q'[.ut_compound_data_tmp where data_id = :other_guid) x,]'
                     ||q'[xmltable('/ROWSET/ROW' passing x.item_data columns ]' ;
    ut_utils.append_to_clob(l_compare_sql,l_temp_string);
    ut_utils.append_to_clob(l_compare_sql,l_xmltable_stmt||q'[ ,item_data xmltype PATH '*') ucd)]');
          
    if a_join_by_xpath is null then
     -- If no key defined do the join on all columns
     l_temp_string :=  q'[ select a.item_data as act_item_data, a.data_id act_data_id, e.item_data as exp_item_data, e.data_id exp_data_id, rownum item_no ]'
                       || q'[from act a full outer join exp e on ( ]';
     ut_utils.append_to_clob(l_compare_sql,l_temp_string);
     ut_utils.append_to_clob(l_compare_sql,ut_compound_data_helper.generate_equal_sql(l_act_col_tab)||q'[ ) where a.data_id is null or e.data_id is null]');
   else
     -- If key defined do the join or these and where on diffrences
     l_temp_string :=  q'[ select a.item_data act_item_data, a.data_id act_data_id,]'
                       ||' e.item_data exp_item_data, e.data_id exp_data_id, rownum item_no from act a full outer join exp e on ( ';
     ut_utils.append_to_clob(l_compare_sql,l_temp_string); 
     
     ut_utils.append_to_clob(l_compare_sql,ut_compound_data_helper.generate_join_by_on_stmt (l_pk_xpath_tabs)||' ) ');
     
     l_where_stmt   := ut_compound_data_helper.generate_not_equal_sql(l_act_col_tab, l_pk_xpath_tabs);
     case 
       when l_where_stmt is null then
         null;
       else
         ut_utils.append_to_clob(l_compare_sql,' where ( '||l_where_stmt||' ) or ( a.data_id is null or e.data_id is null )'); 
     end case;
   end if;     
    return l_compare_sql;
  end;
 
  procedure insert_diffs_result(a_diff_tab t_diff_tab, a_diff_id raw) is
  begin  
    forall idx in 1..a_diff_tab.count
    insert into ut3.ut_compound_data_diff_tmp
    ( diff_id, act_item_data, act_data_id, exp_item_data, exp_data_id, item_no )
    values 
    (a_diff_id, xmlelement( name "ROW", a_diff_tab(idx).act_item_data), a_diff_tab(idx).act_data_id,xmlelement( name "ROW", a_diff_tab(idx).exp_item_data), a_diff_tab(idx).exp_data_id,a_diff_tab(idx).item_no);         
  end;
  
  procedure set_rows_diff(a_rows_diff integer) is
  begin
    gc_diff_count := a_rows_diff;
  end;
  
  procedure cleanup_diff is
  begin
    gc_diff_count := 0;
  end;
  
  function get_rows_diff return integer is
  begin
    return gc_diff_count;
  end;
  
end;
/
