-- FUNCTION: property.get_rule_record(text)

-- DROP FUNCTION IF EXISTS property.get_rule_record(text);

CREATE OR REPLACE FUNCTION property.get_rule_record(
	p_rule_name text)
    RETURNS TABLE(value_numeric numeric, value_text text, value_bool boolean) 
    LANGUAGE 'sql'
    COST 100
    STABLE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
    SELECT value_numeric, value_text, value_bool
    FROM property.property_grz_ldcap_rules
    WHERE rule_name = p_rule_name;
$BODY$;

ALTER FUNCTION property.get_rule_record(text)
    OWNER TO postgres;

GRANT EXECUTE ON FUNCTION property.get_rule_record(text) TO PUBLIC;

GRANT EXECUTE ON FUNCTION property.get_rule_record(text) TO postgres;

GRANT EXECUTE ON FUNCTION property.get_rule_record(text) TO wdc;

GRANT EXECUTE ON FUNCTION property.get_rule_record(text) TO wdc_gisprod;

