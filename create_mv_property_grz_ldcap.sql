-- PROCEDURE: property.create_mv_property_grz_ldcap()

-- DROP PROCEDURE IF EXISTS property.create_mv_property_grz_ldcap();

CREATE OR REPLACE PROCEDURE property.create_mv_property_grz_ldcap(
	)
LANGUAGE 'sql'
AS $BODY$


DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_summary_suburbs;
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_summary;
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_fully_developed;
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_vacant_viable;
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_infill_viable;
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_fully_developed_testing;
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_infill_viability_testing;
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_vacant_viability_testing;
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_overlays;
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_viability_overlay_analysis;
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_building_quadrant_summary;
DROP MATERIALIZED VIEW IF EXISTS property.property_grz_ldcap_building_quadrant_stats;


CALL property.create_mv_property_grz_ldcap_building_quadrant_stats();
CALL property.create_mv_property_grz_ldcap_building_quadrant_summary();

CALL property.create_mv_property_grz_ldcap_viability_overlay_analysis();

CALL property.create_mv_property_grz_ldcap_overlays();


CALL property.create_mv_property_grz_ldcap_infill_viability_testing();
CALL property.create_mv_property_grz_ldcap_vacant_viability_testing();
CALL property.create_mv_property_grz_ldcap_fully_developed_testing();

CALL property.create_mv_property_grz_ldcap_infill_viable();
CALL property.create_mv_property_grz_ldcap_vacant_viable();
CALL property.create_mv_property_grz_ldcap_fully_developed();

CALL property.create_mv_property_grz_ldcap_summary();
CALL property.create_mv_property_grz_ldcap_summary_suburbs();

$BODY$;

ALTER PROCEDURE property.create_mv_property_grz_ldcap()
    OWNER TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap() TO PUBLIC;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap() TO postgres;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap() TO wdc;

GRANT EXECUTE ON PROCEDURE property.create_mv_property_grz_ldcap() TO wdc_gisprod;

