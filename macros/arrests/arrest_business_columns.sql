{% macro arrest_business_columns() %}
    {{ return([
        'arrest_occurred_date_time', 'arrest_reported_date_time', 'report_number', 'arrest_type',
        'precinct', 'sector', 'beat', 'cad_clearance', 'cad_initial_call_type', 'cad_priority',
        'crisis_involved', 'complaint_involved', 'force_involved', 'terry_stop', 'demonstration',
        'officer_id', 'officer_age', 'officer_gender', 'officer_race', 'officer_squad', 'officer_title',
        'subject_id', 'subject_age_range', 'subject_gender', 'subject_race'
    ] + arrest_location_columns()) }}
{% endmacro %}

{% macro arrest_location_columns() %}
    {{ return(['block_address', 'latitude', 'longitude', 'neighborhood', 'reporting_area', 'census_block_2020']) }}
{% endmacro %}

{% macro arrest_location_is_redacted(redacted_flag) %}
    ({{ redacted_flag }}
    {% for column in arrest_location_columns() %}
        and {{ column }} is null
    {% endfor %}
    )
{% endmacro %}
