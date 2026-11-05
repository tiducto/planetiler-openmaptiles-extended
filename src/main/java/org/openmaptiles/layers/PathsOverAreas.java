package org.openmaptiles.layers;

import com.onthegomap.planetiler.VectorTile;
import com.onthegomap.planetiler.geo.GeoUtils;
import com.onthegomap.planetiler.geo.GeometryException;
import com.onthegomap.planetiler.geo.GeometryType;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import org.locationtech.jts.geom.Geometry;
import org.locationtech.jts.geom.LineString;
import org.locationtech.jts.geom.util.LineStringExtracter;
import org.openmaptiles.generated.OpenMapTilesSchema.Transportation.FieldValues;
import org.openmaptiles.generated.OpenMapTilesSchema.Transportation.Fields;

final class PathsOverAreas {

  static final int MIN_ZOOM = 13;
  static final double EDGE_TOLERANCE = 1d / 64;

  private static final List<String> KIND_PRIORITY = List.of(
    FieldValues.OVER_PLATFORM,
    FieldValues.OVER_PIER,
    FieldValues.OVER_PEDESTRIAN
  );

  private record Area(Geometry geometry, String kind, long layer) {}

  private PathsOverAreas() {}

  static List<VectorTile.Feature> split(List<VectorTile.Feature> items) {
    List<Area> areas = areas(items);
    if (areas.isEmpty()) {
      return items;
    }
    List<VectorTile.Feature> result = new ArrayList<>(items.size());
    for (var item : items) {
      if (isSurfacePath(item)) {
        split(item, areas, result);
      } else {
        result.add(item);
      }
    }
    return result;
  }

  private static List<Area> areas(List<VectorTile.Feature> items) {
    List<Area> areas = new ArrayList<>();
    for (var item : items) {
      String kind = areaKind(item);
      Geometry geometry = kind == null ? null : decode(item);
      if (geometry != null) {
        areas.add(new Area(geometry.buffer(EDGE_TOLERANCE), kind, layer(item)));
      }
    }
    areas.sort(Comparator.comparingInt(area -> priority(area.kind)));
    return areas;
  }

  private static void split(VectorTile.Feature path, List<Area> areas, List<VectorTile.Feature> result) {
    Geometry remaining = decode(path);
    if (remaining == null) {
      result.add(path);
      return;
    }
    var envelope = remaining.getEnvelopeInternal();
    long layer = layer(path);
    boolean crossed = false;
    for (Area area : areas) {
      if (area.layer != layer || !area.geometry.getEnvelopeInternal().intersects(envelope)) {
        continue;
      }
      Geometry inside = lines(remaining.intersection(area.geometry));
      if (inside.isEmpty()) {
        continue;
      }
      result.add(path.copyWithNewGeometry(inside).copyWithExtraAttrs(Map.of(Fields.OVER, area.kind)));
      remaining = lines(remaining.difference(area.geometry));
      crossed = true;
      if (remaining.isEmpty()) {
        break;
      }
    }
    if (!crossed) {
      result.add(path);
    } else if (!remaining.isEmpty()) {
      result.add(path.copyWithNewGeometry(remaining).copyWithExtraAttrs(Map.of()));
    }
  }

  private static String areaKind(VectorTile.Feature item) {
    if (item.geometry().geomType() != GeometryType.POLYGON) {
      return null;
    }
    Object clazz = item.tags().get(Fields.CLASS);
    if ("pier".equals(clazz)) {
      return FieldValues.OVER_PIER;
    }
    if (FieldValues.CLASS_PATH.equals(clazz) && item.tags().get(Fields.SUBCLASS)instanceof String subclass &&
      FieldValues.OVER_VALUES.contains(subclass)) {
      return subclass;
    }
    return null;
  }

  private static boolean isSurfacePath(VectorTile.Feature item) {
    return item.geometry().geomType() == GeometryType.LINE &&
      FieldValues.CLASS_PATH.equals(item.tags().get(Fields.CLASS)) &&
      item.tags().get(Fields.BRUNNEL) == null &&
      item.tags().get(Fields.INDOOR) == null;
  }

  private static Geometry decode(VectorTile.Feature item) {
    try {
      return item.geometry().decode();
    } catch (GeometryException e) {
      return null;
    }
  }

  private static long layer(VectorTile.Feature item) {
    return item.tags().get(Fields.LAYER)instanceof Number n ? n.longValue() : 0;
  }

  private static int priority(String kind) {
    int index = KIND_PRIORITY.indexOf(kind);
    return index < 0 ? KIND_PRIORITY.size() : index;
  }

  @SuppressWarnings("unchecked")
  private static Geometry lines(Geometry geometry) {
    List<LineString> lines = LineStringExtracter.getLines(geometry);
    return lines.size() == 1 ? lines.getFirst() : GeoUtils.createMultiLineString(lines);
  }
}
