-- Diagnóstico de lectura: dbt show --select mart_crime_socioeconomic_validation --limit 1
with located as (
    select c.crime_id, c.offense_date, c.offense_classification_id,
           a.address_id as matched_address_id, a.cp as address_cp, a.cp_status,
           p.cp as postal_cp, s.cp as socioeconomic_cp,
           s.median_household_income, s.income_top_coded,
           o.offense_classification_id as matched_classification_id
    from {{ ref('fact_crimes') }} c
    left join {{ ref('dim_address') }} a on a.address_id = c.address_id
    left join {{ ref('dim_postal_codes') }} p on p.cp = a.cp
    left join {{ ref('dim_census_socioeconomic') }} s on s.cp = p.cp
    left join {{ ref('dim_offense_classification') }} o
        on o.offense_classification_id = c.offense_classification_id
),

source_stats as (
    select count(*) as original_crime_rows, count(distinct crime_id) as original_distinct_crimes
    from {{ ref('fact_crimes') }}
),

coverage as (
    select count(*) as rows_after_joins,
           coalesce(count_if(postal_cp is not null), 0) as crimes_with_valid_cp,
           coalesce(count_if(socioeconomic_cp is not null), 0) as crimes_with_socioeconomic_data,
           coalesce(count_if(socioeconomic_cp is not null and median_household_income >= 0
                             and not income_top_coded), 0) as crimes_with_uncensored_income,
           coalesce(count_if(postal_cp is not null and offense_date is not null), 0) as eligible_crimes,
           coalesce(count_if(postal_cp is not null and offense_date is not null
                             and socioeconomic_cp is not null), 0) as eligible_crimes_with_socioeconomic_data,
           coalesce(count_if(matched_address_id is null or address_cp is null), 0) as excluded_missing_location,
           coalesce(count_if(address_cp is not null and postal_cp is null), 0) as excluded_invalid_postal_reference,
           coalesce(count_if(postal_cp is not null and offense_date is null), 0) as excluded_missing_date,
           coalesce(count_if(matched_address_id is null), 0) as missing_address,
           coalesce(count_if(address_cp is null and cp_status = 'redacted'), 0) as location_redacted,
           coalesce(count_if(address_cp is null and cp_status = 'missing_coordinates'), 0) as missing_coordinates,
           coalesce(count_if(address_cp is null and cp_status = 'invalid_coordinates'), 0) as invalid_coordinates,
           coalesce(count_if(address_cp is null and cp_status = 'no_match'), 0) as location_no_match,
           coalesce(count_if(address_cp is null and cp_status = 'ambiguous'), 0) as location_ambiguous,
           coalesce(count_if(address_cp is null and cp_status = 'boundary'), 0) as location_boundary,
           coalesce(count_if(postal_cp is not null and offense_date is not null
                             and offense_classification_id is null), 0) as eligible_unclassified_crimes,
           coalesce(count_if(offense_classification_id is not null
                             and matched_classification_id is null), 0) as invalid_classification_references
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
    select coalesce(sum(crime_count), 0) as represented_crimes,
           count(distinct cp) as represented_postal_codes,
           count(distinct case when crime_count > 0 then cp end) as postal_codes_with_crimes,
           count(distinct case when not has_socioeconomic_data then cp end) as represented_postal_codes_without_socioeconomic_data,
           count(distinct case when income_quintile is not null then cp end) as postal_codes_in_quintiles
    from {{ ref('mart_crime_socioeconomic') }}
),

duplicates as (
    select count(*) as duplicate_grain_groups
    from (
        select cp, year, offense_classification_id
        from {{ ref('mart_crime_socioeconomic') }}
        group by cp, year, offense_classification_id
        having count(*) > 1
    )
)

select s.*, c.*, p.*, m.*, d.*,
       c.crimes_with_valid_cp * 100.0 / nullif(s.original_crime_rows, 0) as geographic_coverage_pct,
       c.crimes_with_socioeconomic_data * 100.0 / nullif(s.original_crime_rows, 0) as socioeconomic_coverage_pct,
       c.eligible_crimes_with_socioeconomic_data * 100.0 / nullif(c.eligible_crimes, 0) as eligible_socioeconomic_coverage_pct,
       c.crimes_with_uncensored_income * 100.0 / nullif(s.original_crime_rows, 0) as uncensored_income_coverage_pct,
       c.rows_after_joins - s.original_crime_rows as join_extra_rows,
       c.eligible_crimes - m.represented_crimes as reconciliation_difference,
       s.original_crime_rows - c.eligible_crimes - c.excluded_missing_location
           - c.excluded_invalid_postal_reference - c.excluded_missing_date as unexplained_exclusions
from source_stats s
cross join coverage c
cross join postal_stats p
cross join mart_stats m
cross join duplicates d
