CREATE SCHEMA IF NOT EXISTS openhigis;

SET search_path TO openhigis, public;

/* Stations */

DROP VIEW IF EXISTS station;

CREATE VIEW station
    AS SELECT
        g.id,
        g.name,
        g.remarks,
        g.code as hydroId,
        gs.geom2100 AS geometry,
        gp.altitude AS elevation,
        s.owner_id AS responsibleParty,
        basin.imported_id AS basin,
        surfacewater.imported_id AS surfaceWater
    FROM
        enhydris_gentity g
        INNER JOIN enhydris_gpoint gp ON gp.gentity_ptr_id = g.id
        INNER JOIN enhydris_station s ON s.gpoint_ptr_id = g.id
        INNER JOIN enhydris_openhigis_station gs ON gs.station_ptr_id = g.id
        LEFT JOIN enhydris_openhigis_basin basin ON basin.garea_ptr_id = gs.basin_id
        LEFT JOIN enhydris_openhigis_surfacewater surfacewater
            ON surfacewater.gentity_ptr_id = gs.surface_water_id;

CREATE OR REPLACE FUNCTION insert_into_station() RETURNS TRIGGER
AS $$
DECLARE
  new_basin_id INTEGER;
  new_surface_water_id INTEGER;
BEGIN
    SELECT garea_ptr_id INTO new_basin_id FROM enhydris_openhigis_basin
        WHERE imported_id = NEW.basin;
    SELECT gentity_ptr_id INTO new_surface_water_id
        FROM enhydris_openhigis_surfacewater
        WHERE imported_id = NEW.surfacewater;
    INSERT INTO enhydris_openhigis_station
        (station_ptr_id, geom2100, basin_id, surface_water_id)
        VALUES (NEW.id, NEW.geometry, new_basin_id, new_surface_water_id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER Station_insert
    INSTEAD OF INSERT ON Station
    FOR EACH ROW EXECUTE PROCEDURE insert_into_Station();

CREATE OR REPLACE FUNCTION update_station() RETURNS TRIGGER
AS $$
DECLARE
  new_basin_id INTEGER;
  new_surface_water_id INTEGER;
BEGIN
    SELECT garea_ptr_id INTO new_basin_id FROM enhydris_openhigis_basin
        WHERE imported_id = NEW.basin;
    SELECT gentity_ptr_id INTO new_surface_water_id
        FROM enhydris_openhigis_surfacewater
        WHERE imported_id = NEW.surfacewater;
    UPDATE enhydris_openhigis_station
        SET
            geom2100=NEW.geometry,
            basin_id=new_basin_id,
            surface_water_id=new_surface_water_id
        WHERE station_ptr_id=OLD.id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER station_update
    INSTEAD OF UPDATE ON station
    FOR EACH ROW EXECUTE PROCEDURE update_station();

CREATE OR REPLACE FUNCTION delete_Station()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM enhydris_openhigis_station WHERE station_ptr_id=OLD.id;
    RETURN OLD;
END;
$$;

CREATE TRIGGER Station_delete
    INSTEAD OF DELETE ON Station
    FOR EACH ROW EXECUTE PROCEDURE delete_Station();

/* Functions common to all tables */

CREATE OR REPLACE FUNCTION insert_into_gentity(NEW ANYELEMENT) RETURNS integer
AS $$
DECLARE gentity_id INTEGER;
BEGIN
    INSERT INTO enhydris_gentity (name, code, remarks, geom)
        VALUES (
            COALESCE(NEW.geographicalName, ''),
            COALESCE(NEW.hydroId, ''),
            COALESCE(NEW.remarks, ''),
            ST_Transform(NEW.geometry, 4326)
        )
        RETURNING id INTO gentity_id;
    RETURN gentity_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION insert_into_garea(NEW ANYELEMENT, category_id INTEGER) RETURNS integer
AS $$
DECLARE gentity_id INTEGER;
BEGIN
    gentity_id = openhigis.insert_into_gentity(NEW);
    INSERT INTO enhydris_garea (gentity_ptr_id, category_id)
        VALUES (gentity_id, category_id);
    RETURN gentity_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION insert_into_gpoint(NEW ANYELEMENT) RETURNS integer
AS $$
DECLARE gentity_id INTEGER;
BEGIN
    gentity_id = openhigis.insert_into_gentity(NEW);
    INSERT INTO enhydris_gpoint (gentity_ptr_id, altitude)
        VALUES (gentity_id, NEW.elevation);
    RETURN gentity_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION update_gentity(gentity_id INTEGER, OLD ANYELEMENT, NEW ANYELEMENT)
RETURNS void
AS $$
BEGIN
    UPDATE enhydris_gentity
        SET
            name=NEW.geographicalName,
            code=COALESCE(NEW.hydroId, ''),
            remarks=COALESCE(NEW.remarks, ''),
            geom=ST_Transform(NEW.geometry, 4326)
        WHERE id=gentity_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION insert_into_basin(NEW ANYELEMENT, gentity_id INTEGER)
RETURNS void
AS $$
BEGIN
    INSERT INTO enhydris_openhigis_basin
        (garea_ptr_id, geom2100, man_made, mean_slope, mean_elevation, max_river_length,
        imported_id)
    VALUES (gentity_id, NEW.geometry, NEW.origin = 'manMade',
        NEW.meanSlope, NEW.meanElevation, NEW.maxRiverLength, NEW.id);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION update_basin(gentity_id INTEGER, OLD ANYELEMENT, NEW ANYELEMENT)
RETURNS void
AS $$
BEGIN
    UPDATE enhydris_openhigis_basin
        SET
            geom2100=NEW.geometry,
            man_made=(NEW.origin = 'manMade'),
            mean_slope=NEW.meanSlope,
            mean_elevation=NEW.meanElevation,
            max_river_length=NEW.maxRiverLength
        WHERE garea_ptr_id=gentity_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION insert_into_surfacewater(gentity_id INTEGER, NEW ANYELEMENT)
RETURNS void
AS $$
DECLARE new_river_basin_id INTEGER;
BEGIN
    SELECT garea_ptr_id INTO new_river_basin_id FROM enhydris_openhigis_basin
        WHERE imported_id=NEW.drainsBasin;
    INSERT INTO enhydris_openhigis_surfacewater
        (gentity_ptr_id, geom2100, local_type, man_made, river_basin_id, imported_id)
    VALUES
        (gentity_id, NEW.geometry, NEW.localType, NEW.origin = 'manMade',
         new_river_basin_id, NEW.id);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION update_surfacewater(gentity_id INTEGER, OLD ANYELEMENT, NEW ANYELEMENT)
RETURNS void
AS $$
DECLARE new_river_basin_id INTEGER;
BEGIN
    SELECT garea_ptr_id INTO new_river_basin_id FROM enhydris_openhigis_basin
        WHERE imported_id=NEW.drainsBasin;
    UPDATE enhydris_openhigis_surfacewater
        SET
            geom2100=NEW.geometry,
            local_type=NEW.localType,
            man_made=(NEW.origin = 'manMade'),
            river_basin_id=new_river_basin_id
        WHERE gentity_ptr_id=gentity_id;
END;
$$ LANGUAGE plpgsql;

/* River basin districts */

DROP VIEW IF EXISTS RiverBasinDistrict;

CREATE VIEW RiverBasinDistrict
    AS SELECT
        rbd.imported_id AS id,
        g.name AS geographicalName,
        g.code AS hydroId,
        g.remarks,
        rbd.geom2100 AS geometry,
        ST_Perimeter(rbd.geom2100) / 1000 AS length_km,
        ST_Area(rbd.geom2100) / 1000000 AS area_sqkm
    FROM
        enhydris_gentity g
        INNER JOIN enhydris_openhigis_riverbasindistrict rbd
        ON rbd.garea_ptr_id = g.id;

CREATE OR REPLACE FUNCTION insert_into_RiverBasinDistrict() RETURNS TRIGGER
AS $$
DECLARE gentity_id INTEGER;
BEGIN
    gentity_id = openhigis.insert_into_garea(NEW, 2);
    INSERT INTO enhydris_openhigis_riverbasindistrict
        (garea_ptr_id, geom2100, imported_id)
        VALUES (gentity_id, NEW.geometry, NEW.id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER RiverBasinDistrict_insert
    INSTEAD OF INSERT ON RiverBasinDistrict
    FOR EACH ROW EXECUTE PROCEDURE insert_into_RiverBasinDistrict();

CREATE OR REPLACE FUNCTION update_RiverBasinDistrict() RETURNS TRIGGER
AS $$
DECLARE gentity_id INTEGER;
BEGIN
    SELECT garea_ptr_id INTO gentity_id FROM enhydris_openhigis_riverbasindistrict
        WHERE imported_id=OLD.id;
    PERFORM openhigis.update_gentity(gentity_id, OLD, NEW);
    UPDATE enhydris_openhigis_riverbasindistrict
    SET geom2100=NEW.geometry
    WHERE imported_id=OLD.id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER RiverBasinDistrict_update
    INSTEAD OF UPDATE ON RiverBasinDistrict
    FOR EACH ROW EXECUTE PROCEDURE update_RiverBasinDistrict();

CREATE OR REPLACE FUNCTION delete_RiverBasinDistrict()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE gentity_id INTEGER;
BEGIN
    SELECT garea_ptr_id INTO gentity_id FROM enhydris_openhigis_riverbasindistrict
        WHERE imported_id=OLD.id;
    DELETE FROM enhydris_openhigis_riverbasindistrict WHERE garea_ptr_id=gentity_id;
    DELETE FROM enhydris_garea WHERE gentity_ptr_id=gentity_id;
    DELETE FROM enhydris_gentity WHERE id=gentity_id;
    RETURN OLD;
END;
$$;

CREATE TRIGGER RiverBasinDistrict_delete
    INSTEAD OF DELETE ON RiverBasinDistrict
    FOR EACH ROW EXECUTE PROCEDURE delete_RiverBasinDistrict();

/* Drainage basins */

DROP VIEW IF EXISTS DrainageBasin;

CREATE VIEW DrainageBasin
    AS SELECT
        basin.imported_id as id,
        g.name AS geographicalName,
        g.code AS hydroId,
        g.last_modified AS beginLifespanVersion,
        g.remarks,
        basin.geom2100 AS geometry,
        riverbasin_basin.imported_id AS riverBasin,
        CASE WHEN basin.man_made IS NULL THEN ''
             WHEN basin.man_made THEN 'manMade'
             ELSE 'natural'
             END AS origin,
        drb.hydro_order AS basinOrder,
        drb.hydro_order_scheme AS basinOrderScheme,
        drb.hydro_order_scope AS basinOrderScope,
        ST_Area(basin.geom2100) / 1000000 AS area,
        drb.total_area AS totalArea,
        basin.mean_slope AS meanSlope,
        basin.mean_elevation AS meanElevation,
        basin.max_river_length AS maxRiverLength
    FROM
        enhydris_gentity g
        INNER JOIN enhydris_openhigis_basin basin
            ON basin.garea_ptr_id = g.id
        INNER JOIN enhydris_openhigis_drainagebasin drb
            ON drb.basin_ptr_id = g.id
        INNER JOIN enhydris_openhigis_riverbasin riverbasin
            ON drb.river_basin_id = riverbasin.basin_ptr_id
        INNER JOIN enhydris_openhigis_basin riverbasin_basin
            ON riverbasin_basin.garea_ptr_id = riverbasin.basin_ptr_id;

CREATE OR REPLACE FUNCTION insert_into_DrainageBasin() RETURNS TRIGGER
AS $$
DECLARE
    gentity_id INTEGER;
    new_river_basin_id INTEGER;
BEGIN
    gentity_id = openhigis.insert_into_garea(NEW, 4);
    PERFORM openhigis.insert_into_basin(NEW, gentity_id);
    SELECT garea_ptr_id INTO new_river_basin_id
        FROM enhydris_openhigis_basin
        WHERE imported_id = NEW.riverBasin;
    INSERT INTO enhydris_openhigis_drainagebasin
        (basin_ptr_id, river_basin_id, hydro_order, hydro_order_scheme,
        hydro_order_scope, total_area)
        VALUES (gentity_id, new_river_basin_id, COALESCE(NEW.basinOrder, ''),
            COALESCE(NEW.basinOrderScheme, ''),
            COALESCE(NEW.basinOrderScope, ''), NEW.totalArea
        );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER DrainageBasin_insert
    INSTEAD OF INSERT ON DrainageBasin
    FOR EACH ROW EXECUTE PROCEDURE insert_into_DrainageBasin();

CREATE OR REPLACE FUNCTION update_DrainageBasin() RETURNS TRIGGER
AS $$
DECLARE
    gentity_id INTEGER;
    new_river_basin_id INTEGER;
BEGIN
    SELECT garea_ptr_id INTO gentity_id FROM enhydris_openhigis_basin
        WHERE imported_id=OLD.id;
    SELECT garea_ptr_id INTO new_river_basin_id
        FROM enhydris_openhigis_basin
        WHERE imported_id = NEW.riverBasin;
    PERFORM openhigis.update_gentity(gentity_id, OLD, NEW);
    PERFORM openhigis.update_basin(gentity_id, OLD, NEW);
    UPDATE enhydris_openhigis_drainagebasin
    SET
        river_basin_id=new_river_basin_id,
        hydro_order=COALESCE(NEW.basinOrder, ''),
        hydro_order_scheme=COALESCE(NEW.basinOrderScheme, ''),
        hydro_order_scope=COALESCE(NEW.basinOrderScope, ''),
        total_area=NEW.totalArea
        WHERE basin_ptr_id=gentity_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER DrainageBasin_update
    INSTEAD OF UPDATE ON DrainageBasin
    FOR EACH ROW EXECUTE PROCEDURE update_DrainageBasin();

CREATE OR REPLACE FUNCTION delete_DrainageBasin()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE gentity_id INTEGER;
BEGIN
    SELECT garea_ptr_id INTO gentity_id FROM enhydris_openhigis_basin
        WHERE imported_id=OLD.id;
    DELETE FROM enhydris_openhigis_drainagebasin WHERE basin_ptr_id=gentity_id;
    DELETE FROM enhydris_openhigis_basin WHERE garea_ptr_id=gentity_id;
    DELETE FROM enhydris_garea WHERE gentity_ptr_id=gentity_id;
    DELETE FROM enhydris_gentity WHERE id=gentity_id;
    RETURN OLD;
END;
$$;

CREATE TRIGGER DrainageBasin_delete
    INSTEAD OF DELETE ON DrainageBasin
    FOR EACH ROW EXECUTE PROCEDURE delete_DrainageBasin();

/* River basins */

DROP VIEW IF EXISTS RiverBasin;

CREATE VIEW RiverBasin
    AS SELECT
        basin.imported_id AS id,
        g.name AS geographicalName,
        g.code AS hydroId,
        g.last_modified AS beginLifespanVersion,
        g.remarks,
        basin.geom2100 AS geometry,
        CASE WHEN basin.man_made IS NULL THEN ''
             WHEN basin.man_made THEN 'manMade'
             ELSE 'natural'
             END AS origin,
        ST_Area(basin.geom2100) / 1000000 AS area,
        basin.mean_slope AS meanSlope,
        basin.mean_elevation AS meanElevation,
        basin.max_river_length AS maxRiverLength
    FROM
        enhydris_gentity g
        INNER JOIN enhydris_openhigis_basin basin
            ON basin.garea_ptr_id = g.id
        INNER JOIN enhydris_openhigis_riverbasin rb
        ON rb.basin_ptr_id = g.id;

CREATE OR REPLACE FUNCTION insert_into_RiverBasin() RETURNS TRIGGER
AS $$
DECLARE gentity_id INTEGER;
BEGIN
    gentity_id = openhigis.insert_into_garea(NEW, 3);
    PERFORM openhigis.insert_into_basin(NEW, gentity_id);
    INSERT INTO enhydris_openhigis_riverbasin (basin_ptr_id)
        VALUES (gentity_id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER RiverBasin_insert
    INSTEAD OF INSERT ON RiverBasin
    FOR EACH ROW EXECUTE PROCEDURE insert_into_RiverBasin();

CREATE OR REPLACE FUNCTION update_RiverBasin() RETURNS TRIGGER
AS $$
DECLARE gentity_id INTEGER;
BEGIN
    SELECT garea_ptr_id INTO gentity_id FROM enhydris_openhigis_basin
        WHERE imported_id=OLD.id;
    PERFORM openhigis.update_gentity(gentity_id, OLD, NEW);
    PERFORM openhigis.update_basin(gentity_id, OLD, NEW);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER RiverBasin_update
    INSTEAD OF UPDATE ON RiverBasin
    FOR EACH ROW EXECUTE PROCEDURE update_RiverBasin();

CREATE OR REPLACE FUNCTION delete_RiverBasin()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE gentity_id INTEGER;
BEGIN
    SELECT garea_ptr_id INTO gentity_id FROM enhydris_openhigis_basin
        WHERE imported_id=OLD.id;
    DELETE FROM enhydris_openhigis_riverbasin WHERE basin_ptr_id=gentity_id;
    DELETE FROM enhydris_openhigis_basin WHERE garea_ptr_id=gentity_id;
    DELETE FROM enhydris_garea WHERE gentity_ptr_id=gentity_id;
    DELETE FROM enhydris_gentity WHERE id=gentity_id;
    RETURN OLD;
END;
$$;

CREATE TRIGGER RiverBasin_delete
    INSTEAD OF DELETE ON RiverBasin
    FOR EACH ROW EXECUTE PROCEDURE delete_RiverBasin();

/* Station basins */

DROP VIEW IF EXISTS StationBasin;

CREATE VIEW StationBasin
    AS SELECT
        station_id AS id,
        'Λεκάνη ανάντη του σταθμού ' || station.name AS geographicalName,
        g.code AS hydroId,
        g.last_modified AS beginLifespanVersion,
        g.remarks,
        sb.geom2100 AS geometry,
        riverbasin_basin.imported_id AS riverBasin,
        CASE WHEN sb.man_made IS NULL THEN ''
             WHEN sb.man_made THEN 'manMade'
             ELSE 'natural'
             END AS origin,
        ST_Area(sb.geom2100) / 1000000 AS area,
        sb.mean_slope AS meanSlope,
        sb.mean_elevation AS meanElevation,
        sb.max_river_length AS maxRiverLength
    FROM
        enhydris_gentity g
        INNER JOIN enhydris_openhigis_stationbasin sb
        ON sb.garea_ptr_id = g.id
        INNER JOIN enhydris_openhigis_riverbasin riverbasin
        ON riverbasin.basin_ptr_id = sb.river_basin_id
        INNER JOIN enhydris_openhigis_basin riverbasin_basin
        ON riverbasin_basin.garea_ptr_id = riverbasin.basin_ptr_id
        INNER JOIN enhydris_gentity station
        ON station.id = sb.station_id;

CREATE OR REPLACE FUNCTION insert_into_StationBasin() RETURNS TRIGGER
AS $$
DECLARE
    gentity_id INTEGER;
    new_river_basin_id INTEGER;
BEGIN
    gentity_id = openhigis.insert_into_garea(NEW, 5);
    SELECT garea_ptr_id INTO new_river_basin_id
        FROM enhydris_openhigis_basin
        WHERE imported_id = NEW.riverBasin;
    INSERT INTO enhydris_openhigis_stationbasin
        (garea_ptr_id, geom2100, man_made, mean_slope, mean_elevation,
            max_river_length, river_basin_id, station_id)
        VALUES (gentity_id, NEW.geometry, NEW.origin = 'manMade',
            NEW.meanSlope, NEW.meanElevation, NEW.maxRiverLength,
            new_river_basin_id, NEW.id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER StationBasin_insert
    INSTEAD OF INSERT ON StationBasin
    FOR EACH ROW EXECUTE PROCEDURE insert_into_StationBasin();

CREATE OR REPLACE FUNCTION update_StationBasin() RETURNS TRIGGER
AS $$
DECLARE
    gentity_id INTEGER;
    new_river_basin_id INTEGER;
BEGIN
    SELECT garea_ptr_id INTO gentity_id FROM enhydris_openhigis_stationbasin
        WHERE station_id=OLD.id;
    SELECT garea_ptr_id INTO new_river_basin_id
        FROM enhydris_openhigis_basin
        WHERE imported_id = NEW.riverBasin;
    PERFORM openhigis.update_gentity(gentity_id, OLD, NEW);
    UPDATE enhydris_openhigis_stationbasin
    SET
        geom2100=NEW.geometry,
        man_made=(NEW.origin = 'manMade'),
        mean_slope=NEW.meanSlope,
        mean_elevation=NEW.meanElevation,
        max_river_length=NEW.maxRiverLength,
        river_basin_id=new_river_basin_id
        WHERE station_id=OLD.id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER StationBasin_update
    INSTEAD OF UPDATE ON StationBasin
    FOR EACH ROW EXECUTE PROCEDURE update_StationBasin();

CREATE OR REPLACE FUNCTION delete_StationBasin()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE gentity_id INTEGER;
BEGIN
    SELECT garea_ptr_id INTO gentity_id FROM enhydris_openhigis_stationbasin
        WHERE station_id=OLD.id;
    DELETE FROM enhydris_openhigis_stationbasin WHERE garea_ptr_id=gentity_id;
    DELETE FROM enhydris_garea WHERE gentity_ptr_id=gentity_id;
    DELETE FROM enhydris_gentity WHERE id=gentity_id;
    RETURN OLD;
END;
$$;

CREATE TRIGGER StationBasin_delete
    INSTEAD OF DELETE ON StationBasin
    FOR EACH ROW EXECUTE PROCEDURE delete_StationBasin();

/* Watercourses */

DROP VIEW IF EXISTS Watercourse;

CREATE VIEW Watercourse
    AS SELECT
        surfacewater.imported_id as id,
        g.name AS geographicalName,
        g.code AS hydroId,
        g.last_modified AS beginLifespanVersion,
        g.remarks,
        surfacewater.geom2100 AS geometry,
        riverbasin_basin.imported_id AS drainsBasin,
        CASE WHEN surfacewater.man_made IS NULL THEN ''
             WHEN surfacewater.man_made THEN 'manMade'
             ELSE 'natural'
             END AS origin,
        watercourse.hydro_order AS streamOrder,
        watercourse.hydro_order_scheme AS streamOrderScheme,
        watercourse.hydro_order_scope AS streamOrderScope,
        ST_LENGTH(surfacewater.geom2100) / 1000 AS length,
        surfacewater.local_type AS localType,
        watercourse.min_width AS lowerWidth,
        watercourse.max_width AS upperWidth,
        start_node.imported_id AS startNode,
        end_node.imported_id AS endNode
    FROM
        enhydris_gentity g
        INNER JOIN enhydris_openhigis_surfacewater surfacewater
            ON surfacewater.gentity_ptr_id = g.id
        INNER JOIN enhydris_openhigis_watercourse watercourse
            ON watercourse.surfacewater_ptr_id = g.id
        LEFT JOIN enhydris_openhigis_riverbasin riverbasin
            ON surfacewater.river_basin_id = riverbasin.basin_ptr_id
        LEFT JOIN enhydris_openhigis_basin riverbasin_basin
            ON riverbasin_basin.garea_ptr_id = riverbasin.basin_ptr_id
        LEFT JOIN enhydris_openhigis_hydronode start_node
            ON watercourse.start_node_id = start_node.imported_id
        LEFT JOIN enhydris_openhigis_hydronode end_node
            ON watercourse.start_node_id = end_node.imported_id;


CREATE OR REPLACE FUNCTION insert_into_Watercourse() RETURNS TRIGGER
AS $$
DECLARE
    gentity_id INTEGER;
    new_start_node_id INTEGER;
    new_end_node_id INTEGER;
BEGIN
    gentity_id = openhigis.insert_into_gentity(NEW);
    SELECT gpoint_ptr_id INTO new_start_node_id FROM enhydris_openhigis_hydronode
        WHERE imported_id=NEW.startNode;
    SELECT gpoint_ptr_id INTO new_end_node_id FROM enhydris_openhigis_hydronode
        WHERE imported_id=NEW.endNode;
    PERFORM openhigis.insert_into_surfacewater(gentity_id, NEW);
    INSERT INTO enhydris_openhigis_watercourse
        (surfacewater_ptr_id, hydro_order, hydro_order_scheme, hydro_order_scope,
            min_width, max_width, start_node_id, end_node_id)
        VALUES (gentity_id,
            COALESCE(NEW.streamOrder, ''),
            COALESCE(NEW.streamOrderScheme, ''),
            COALESCE(NEW.streamOrderScope, ''),
            NEW.lowerWidth, NEW.upperWidth, new_start_node_id, new_end_node_id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER Watercourse_insert
    INSTEAD OF INSERT ON Watercourse
    FOR EACH ROW EXECUTE PROCEDURE insert_into_Watercourse();

CREATE OR REPLACE FUNCTION update_Watercourse() RETURNS TRIGGER
AS $$
DECLARE
    gentity_id INTEGER;
    new_start_node_id INTEGER;
    new_end_node_id INTEGER;
BEGIN
    SELECT gentity_ptr_id INTO gentity_id FROM enhydris_openhigis_surfacewater
        WHERE imported_id=OLD.id;
    PERFORM openhigis.update_gentity(gentity_id, OLD, NEW);
    PERFORM openhigis.update_surfacewater(gentity_id, OLD, NEW);
    SELECT gpoint_ptr_id INTO new_start_node_id FROM enhydris_openhigis_hydronode
        WHERE imported_id=NEW.startNode;
    SELECT gpoint_ptr_id INTO new_end_node_id FROM enhydris_openhigis_hydronode
        WHERE imported_id=NEW.endNode;
    UPDATE enhydris_openhigis_watercourse
    SET
        hydro_order=COALESCE(NEW.streamOrder, ''),
        hydro_order_scheme=COALESCE(NEW.streamOrderScheme, ''),
        hydro_order_scope=COALESCE(NEW.streamOrderScope, ''),
        min_width=NEW.lowerWidth,
        max_width=NEW.upperWidth,
        start_node_id=new_start_node_id,
        end_node_id=new_end_node_id
        WHERE surfacewater_ptr_id=gentity_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER Watercourse_update
    INSTEAD OF UPDATE ON Watercourse
    FOR EACH ROW EXECUTE PROCEDURE update_Watercourse();

CREATE OR REPLACE FUNCTION delete_Watercourse()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE gentity_id INTEGER;
BEGIN
    SELECT gentity_ptr_id INTO gentity_id FROM enhydris_openhigis_surfacewater
        WHERE imported_id=OLD.id;
    DELETE FROM enhydris_openhigis_watercourse WHERE surfacewater_ptr_id=gentity_id;
    DELETE FROM enhydris_openhigis_surfacewater WHERE gentity_ptr_id=gentity_id;
    DELETE FROM enhydris_gentity WHERE id=gentity_id;
    RETURN OLD;
END;
$$;

CREATE TRIGGER Watercourse_delete
    INSTEAD OF DELETE ON Watercourse
    FOR EACH ROW EXECUTE PROCEDURE delete_Watercourse();

/* StandingWater */

DROP VIEW IF EXISTS StandingWater;

CREATE VIEW StandingWater
    AS SELECT
        surfacewater.imported_id as id,
        g.name AS geographicalName,
        g.code AS hydroId,
        g.last_modified AS beginLifespanVersion,
        g.remarks,
        surfacewater.geom2100 AS geometry,
        riverbasin_basin.imported_id AS drainsBasin,
        CASE WHEN surfacewater.man_made IS NULL THEN ''
             WHEN surfacewater.man_made THEN 'manMade'
             ELSE 'natural'
             END AS origin,
        ST_LENGTH(surfacewater.geom2100) / 1000 AS length,
        surfacewater.local_type AS localType,
        standingwater.elevation AS elevation,
        standingwater.mean_depth AS meanDepth,
        ST_Area(surfacewater.geom2100) / 1000000 AS area
    FROM
        enhydris_gentity g
        INNER JOIN enhydris_openhigis_surfacewater surfacewater
            ON surfacewater.gentity_ptr_id = g.id
        INNER JOIN enhydris_openhigis_standingwater standingwater
            ON standingwater.surfacewater_ptr_id = g.id
        LEFT JOIN enhydris_openhigis_riverbasin riverbasin
            ON surfacewater.river_basin_id = riverbasin.basin_ptr_id
        LEFT JOIN enhydris_openhigis_basin riverbasin_basin
            ON riverbasin_basin.garea_ptr_id = riverbasin.basin_ptr_id;

CREATE OR REPLACE FUNCTION insert_into_StandingWater() RETURNS TRIGGER
AS $$
DECLARE gentity_id INTEGER;
BEGIN
    gentity_id = openhigis.insert_into_gentity(NEW);
    PERFORM openhigis.insert_into_surfacewater(gentity_id, NEW);
    INSERT INTO enhydris_openhigis_standingwater
        (surfacewater_ptr_id, elevation, mean_depth)
        VALUES (gentity_id, NEW.elevation, NEW.meanDepth);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER StandingWater_insert
    INSTEAD OF INSERT ON StandingWater
    FOR EACH ROW EXECUTE PROCEDURE insert_into_StandingWater();

CREATE OR REPLACE FUNCTION update_StandingWater() RETURNS TRIGGER
AS $$
DECLARE gentity_id INTEGER;
BEGIN
    SELECT gentity_ptr_id INTO gentity_id FROM enhydris_openhigis_surfacewater
        WHERE imported_id=OLD.id;
    PERFORM openhigis.update_gentity(gentity_id, OLD, NEW);
    PERFORM openhigis.update_surfacewater(gentity_id, OLD, NEW);
    UPDATE enhydris_openhigis_standingwater
    SET
        elevation=NEW.elevation,
        mean_depth=NEW.meanDepth
        WHERE surfacewater_ptr_id=gentity_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER StandingWater_update
    INSTEAD OF UPDATE ON StandingWater
    FOR EACH ROW EXECUTE PROCEDURE update_StandingWater();

CREATE OR REPLACE FUNCTION delete_StandingWater()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE gentity_id INTEGER;
BEGIN
    SELECT gentity_ptr_id INTO gentity_id FROM enhydris_openhigis_surfacewater
        WHERE imported_id=OLD.id;
    DELETE FROM enhydris_openhigis_standingwater WHERE surfacewater_ptr_id=gentity_id;
    DELETE FROM enhydris_openhigis_surfacewater WHERE gentity_ptr_id=gentity_id;
    DELETE FROM enhydris_gentity WHERE id=gentity_id;
    RETURN OLD;
END;
$$;

CREATE TRIGGER StandingWater_delete
    INSTEAD OF DELETE ON StandingWater
    FOR EACH ROW EXECUTE PROCEDURE delete_StandingWater();

/* Nodes */

DROP VIEW IF EXISTS HydroNode;

CREATE VIEW HydroNode
    AS SELECT
        hn.imported_id AS id,
        g.name as geographicalName,
        g.remarks,
        g.code as hydroId,
        hn.geom2100 AS geometry,
        gp.altitude AS elevation
    FROM
        enhydris_gentity g
        INNER JOIN enhydris_gpoint gp ON gp.gentity_ptr_id = g.id
        INNER JOIN enhydris_openhigis_hydronode hn ON hn.gpoint_ptr_id = g.id;

CREATE OR REPLACE FUNCTION insert_into_HydroNode() RETURNS TRIGGER
AS $$
DECLARE gentity_id INTEGER;
BEGIN
    gentity_id = openhigis.insert_into_gpoint(NEW);
    INSERT INTO enhydris_openhigis_hydronode
        (gpoint_ptr_id, geom2100, imported_id)
        VALUES (gentity_id, NEW.geometry, NEW.id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER HydroNode_insert
    INSTEAD OF INSERT ON HydroNode
    FOR EACH ROW EXECUTE PROCEDURE insert_into_HydroNode();

CREATE OR REPLACE FUNCTION update_HydroNode() RETURNS TRIGGER
AS $$
DECLARE gentity_id INTEGER;
BEGIN
    SELECT gpoint_ptr_id INTO gentity_id FROM enhydris_openhigis_hydronode
        WHERE imported_id=OLD.id;
    PERFORM openhigis.update_gentity(gentity_id, OLD, NEW);
    UPDATE enhydris_gpoint
        SET altitude=NEW.elevation
        WHERE gentity_ptr_id=gentity_id;
    UPDATE enhydris_openhigis_hydronode
        SET geom2100=NEW.geometry
        WHERE imported_id=OLD.id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER HydroNode_update
    INSTEAD OF UPDATE ON HydroNode
    FOR EACH ROW EXECUTE PROCEDURE update_HydroNode();

CREATE OR REPLACE FUNCTION delete_HydroNode()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE gentity_id INTEGER;
BEGIN
    SELECT gpoint_ptr_id INTO gentity_id FROM enhydris_openhigis_hydronode
        WHERE imported_id=OLD.id;
    DELETE FROM enhydris_openhigis_hydronode WHERE gpoint_ptr_id=gentity_id;
    DELETE FROM enhydris_gpoint WHERE gentity_ptr_id=gentity_id;
    DELETE FROM enhydris_gentity WHERE id=gentity_id;
    RETURN OLD;
END;
$$;

CREATE TRIGGER HydroNode_delete
    INSTEAD OF DELETE ON HydroNode
    FOR EACH ROW EXECUTE PROCEDURE delete_HydroNode();

/* Give permissions */

GRANT USAGE ON SCHEMA openhigis TO mapserver, anton;
GRANT SELECT ON ALL TABLES IN SCHEMA openhigis TO mapserver;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA openhigis TO anton;
GRANT SELECT, INSERT, UPDATE, DELETE
    ON
    enhydris_openhigis_basin,
    enhydris_openhigis_riverbasin,
    enhydris_openhigis_drainagebasin,
    enhydris_openhigis_riverbasindistrict,
    enhydris_openhigis_stationbasin,
    enhydris_openhigis_station,
    enhydris_openhigis_surfacewater,
    enhydris_openhigis_watercourse,
    enhydris_openhigis_standingwater,
    enhydris_openhigis_hydronode,
    enhydris_garea,
    enhydris_gpoint,
    enhydris_gentity
    TO anton;
