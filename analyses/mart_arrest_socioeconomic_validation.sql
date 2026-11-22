-- Diagnóstico de lectura: dbt show --select mart_arrest_socioeconomic_validation --limit 1
with located as (
    select r.arrest_number, r.arrest_occurred_date,
           a.address_id as matched_address_id, a.cp as address_cp, a.cp_status,
           p.cp as postal_cp, s.cp as socioeconomic_cp,
           s.median_household_income, s.income_top_coded
    from {{ ref('fact_arrests') }} r
    left join {{ ref('dim_address') }} a on a.address_id = r.address_id
    left join {{ ref('dim_postal_codes') }} p on p.cp = a.cp
    left join {{ ref('dim_census_socioeconomic') }} s on s.cp = p.cp
),

source_stats as (
    select count(*) as original_arrest_rows, count(distinct arrest_number) as original_distinct_arrests
    from {{ ref('fact_arrests') }}
),

coverage as (
    select count(*) as rows_after_joins,
           coalesce(count_if(postal_cp is not null), 0) as arrests_with_valid_cp,
           coalesce(count_if(socioeconomic_cp is not null), 0) as arrests_with_socioeconomic_data,
           coalesce(count_if(socioeconomic_cp is not null and median_household_income >= 0
                             and not income_top_coded), 0) as arrests_with_uncensored_income,
           coalesce(count_if(postal_cp is not null and arrest_occurred_date is not null), 0) as arrests_with_postal_year,
           coalesce(count_if(postal_cp is not null and arrest_occurred_date is not null
                             and socioeconomic_cp is not null), 0) as postal_year_arrests_with_socioeconomic_data,
           coalesce(count_if(matched_address_id is null or address_cp is null), 0) as arrests_without_postal_location,
           coalesce(count_if(address_cp is not null and postal_cp is null), 0) as arrests_without_postal_reference,
           coalesce(count_if(arrest_occurred_date is null), 0) as arrests_without_date,
           coalesce(count_if(matched_address_id is null), 0) as missing_address,
           coalesce(count_if(address_cp is null and cp_status = 'redacted'), 0) as location_redacted,
           coalesce(count_if(address_cp is null and cp_status = 'missing_coordinates'), 0) as missing_coordinates,
           coalesce(count_if(address_cp is null and cp_status = 'invalid_coordinates'), 0) as invalid_coordinates,
           coalesce(count_if(address_cp is null and cp_status = 'no_match'), 0) as location_no_match,
           coalesce(count_if(address_cp is null and cp_status = 'ambiguous'), 0) as location_ambiguous,
           coalesce(count_if(address_cp is null and cp_status = 'boundary'), 0) as location_boundary
    from located
),

postal_stats as (
    select count(*) as catalog_postal_codes,
           coalesce(count_if(s.cp is null), 0) as postal_codes_without_socioeconomic_data,
           coalesce(count_if(p.geography is null), 0) as postal_codes_without_geometry
    from {{ ref('dim_postal_codes') }} p
    left join {{ ref('dim_census_socioeconomic') }} s on s.cp = p.cp
),

mart_stats as (
    select coalesce(sum(arrest_count), 0) as represented_arrests,
           count(*) as mart_rows,
           count(distinct cp) as represented_postal_codes,
           count(distinct case when arrest_count > 0 then cp end) as postal_codes_with_arrests,
           count(distinct case when not has_socioeconomic_data then cp end) as represented_postal_codes_without_socioeconomic_data,
           count(distinct case when income_quintile is not null then cp end) as represented_postal_codes_in_quintiles,
           coalesce(count_if(block_address is not null and not is_location_redacted), 0) as arrests_with_published_address,
           coalesce(count_if(point_geography is not null), 0) as arrests_with_mappable_point,
           coalesce(count_if(not has_address_data or cp is null), 0) as retained_without_postal_location,
           coalesce(count_if(cp is not null and not has_postal_reference), 0) as retained_without_postal_reference,
           coalesce(count_if(arrest_occurred_date is null), 0) as retained_without_date
    from {{ ref('mart_arrest_socioeconomic') }}
),

duplicates as (
    select count(*) as duplicate_grain_groups
    from (
        select arrest_number
        from {{ ref('mart_arrest_socioeconomic') }}
        group by arrest_number
        having count(*) > 1
    )
)

select s.*, c.*, p.*, m.*, d.*,
       c.arrests_with_valid_cp * 100.0 / nullif(s.original_arrest_rows, 0) as geographic_coverage_pct,
       c.arrests_with_socioeconomic_data * 100.0 / nullif(s.original_arrest_rows, 0) as socioeconomic_coverage_pct,
       c.postal_year_arrests_with_socioeconomic_data * 100.0 / nullif(c.arrests_with_postal_year, 0) as postal_year_socioeconomic_coverage_pct,
       c.arrests_with_uncensored_income * 100.0 / nullif(s.original_arrest_rows, 0) as uncensored_income_coverage_pct,
       c.rows_after_joins - s.original_arrest_rows as join_extra_rows,
       s.original_arrest_rows - m.represented_arrests as reconciliation_difference,
       s.original_arrest_rows - m.mart_rows as excluded_arrests,
       m.arrests_with_published_address * 100.0 / nullif(s.original_arrest_rows, 0) as published_address_coverage_pct,
       m.arrests_with_mappable_point * 100.0 / nullif(s.original_arrest_rows, 0) as point_coverage_pct
from source_stats s
cross join coverage c
cross join postal_stats p
cross join mart_stats m
cross join duplicates d
