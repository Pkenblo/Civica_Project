select
      cp
    , zcta_name
    , median_household_income
    , income_margin_of_error
    , population
    , median_home_value
    , median_monthly_rent
    , income_top_coded
    , home_value_top_coded
    , rent_top_coded
    , ingested_at
    , source_file
    , batch_id
from {{ ref('census_socioeconomic') }}
