part of 'polyline_layer.dart';

/// [CustomPainter] for [Polyline]s.
class _PolylinePainter<R extends Object> extends CustomPainter {
  /// Reference to the list of [Polyline]s.
  final List<_ProjectedPolyline<R>> polylines;

  /// Reference to the [MapCamera].
  final MapCamera camera;
  final LayerHitNotifier<R>? hitNotifier;
  final double minimumHitbox;

  final _hits = <R>[]; // Avoids repetitive memory reallocation

  /// Create a new [_PolylinePainter] instance
  _PolylinePainter({
    required this.polylines,
    required this.camera,
    required this.hitNotifier,
    required this.minimumHitbox,
  });

  @override
  bool? hitTest(Offset position) {
    _hits.clear();
    bool hasHit = false;

    final origin =
        camera.project(camera.center).toOffset() - camera.size.toOffset() / 2;

    for (final projectedPolyline in polylines.reversed) {
      final polyline = projectedPolyline.polyline;
      if (hasHit && polyline.hitValue == null) continue;

      // TODO: For efficiency we'd ideally filter by bounding box here. However
      // we'd need to compute an extended bounding box that accounts account for
      // the `borderStrokeWidth` & the `minimumHitbox`
      // if (!polyline.boundingBox.contains(touch)) {
      //   continue;
      // }

      final offsets = getOffsetsXY(
        camera: camera,
        origin: origin,
        points: projectedPolyline.points,
      );
      final strokeWidth = polyline.useStrokeWidthInMeter
          ? _metersToStrokeWidth(
              origin,
              _unproject(projectedPolyline.points.first),
              offsets.first,
              polyline.strokeWidth,
            )
          : polyline.strokeWidth;
      final hittableDistance = math.max(
        strokeWidth / 2 + polyline.borderStrokeWidth / 2,
        minimumHitbox,
      );

      for (int i = 0; i < offsets.length - 1; i++) {
        final o1 = offsets[i];
        final o2 = offsets[i + 1];

        final distanceSq =
            getSqSegDist(position.dx, position.dy, o1.dx, o1.dy, o2.dx, o2.dy);

        if (distanceSq <= hittableDistance * hittableDistance) {
          if (polyline.hitValue != null) _hits.add(polyline.hitValue!);
          hasHit = true;
          break;
        }
      }
    }

    if (!hasHit) {
      hitNotifier?.value = null;
      return false;
    }

    final point = position.toPoint();
    hitNotifier?.value = LayerHitResult(
      hitValues: _hits,
      coordinate: camera.pointToLatLng(point),
      point: point,
    );
    return true;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    var path = ui.Path();
    var borderPath = ui.Path();
    var filterPath = ui.Path();
    var paint = Paint();
    var needsLayerSaving = false;

    Paint? borderPaint;
    Paint? filterPaint;
    int? lastHash;

    void drawPaths() {
      final hasBorder = borderPaint != null && filterPaint != null;
      if (hasBorder) {
        if (needsLayerSaving) {
          canvas.saveLayer(rect, Paint());
        }

        canvas.drawPath(borderPath, borderPaint!);
        borderPath = ui.Path();
        borderPaint = null;

        if (needsLayerSaving) {
          canvas.drawPath(filterPath, filterPaint!);
          filterPath = ui.Path();
          filterPaint = null;

          canvas.restore();
        }
      }

      canvas.drawPath(path, paint);
      path = ui.Path();
      paint = Paint();
    }

    final origin =
        camera.project(camera.center).toOffset() - camera.size.toOffset() / 2;

    for (final projectedPolyline in polylines) {
      final polyline = projectedPolyline.polyline;
      final offsets = getOffsetsXY(
        camera: camera,
        origin: origin,
        points: projectedPolyline.points,
      );
      if (offsets.isEmpty) {
        continue;
      }

      final hash = polyline.renderHashCode;
      if (needsLayerSaving || (lastHash != null && lastHash != hash)) {
        drawPaths();
      }
      lastHash = hash;
      needsLayerSaving = polyline.color.opacity < 1.0 ||
          (polyline.gradientColors?.any((c) => c.opacity < 1.0) ?? false);

      late final double strokeWidth;
      if (polyline.useStrokeWidthInMeter) {
        strokeWidth = _metersToStrokeWidth(
          origin,
          _unproject(projectedPolyline.points.first),
          offsets.first,
          polyline.strokeWidth,
        );
      } else {
        strokeWidth = polyline.strokeWidth;
      }

      final isDashed = polyline.pattern.segments != null;
      final isDotted = polyline.pattern.spacingFactor != null;

      paint = Paint()
        ..strokeWidth = strokeWidth
        ..strokeCap = polyline.strokeCap
        ..strokeJoin = polyline.strokeJoin
        ..style = isDotted ? PaintingStyle.fill : PaintingStyle.stroke
        ..blendMode = BlendMode.srcOver;

      if (polyline.gradientColors == null) {
        paint.color = polyline.color;
      } else {
        polyline.gradientColors!.isNotEmpty
            ? paint.shader = _paintGradient(polyline, offsets)
            : paint.color = polyline.color;
      }

      if (polyline.borderStrokeWidth > 0.0) {
        // Outlined lines are drawn by drawing a thicker path underneath, then
        // stenciling the middle (in case the line fill is transparent), and
        // finally drawing the line fill.
        borderPaint = Paint()
          ..color = polyline.borderColor
          ..strokeWidth = strokeWidth + polyline.borderStrokeWidth
          ..strokeCap = polyline.strokeCap
          ..strokeJoin = polyline.strokeJoin
          ..style = isDotted ? PaintingStyle.fill : PaintingStyle.stroke
          ..blendMode = BlendMode.srcOver;

        filterPaint = Paint()
          ..color = polyline.borderColor.withAlpha(255)
          ..strokeWidth = strokeWidth
          ..strokeCap = polyline.strokeCap
          ..strokeJoin = polyline.strokeJoin
          ..style = isDotted ? PaintingStyle.fill : PaintingStyle.stroke
          ..blendMode = BlendMode.dstOut;
      }

      final radius = paint.strokeWidth / 2;
      final borderRadius = (borderPaint?.strokeWidth ?? 0) / 2;

      final List<ui.Path> paths = [];
      if (borderPaint != null && filterPaint != null) {
        paths.add(borderPath);
        paths.add(filterPath);
      }
      paths.add(path);
      if (isDotted) {
        final DottedPixelHiker hiker = DottedPixelHiker(
          offsets: offsets,
          stepLength: strokeWidth * polyline.pattern.spacingFactor!,
          patternFit: polyline.pattern.patternFit!,
          closePath: false,
          canvasSize: size,
        );

        final List<double> radii = [];
        if (borderPaint != null && filterPaint != null) {
          radii.add(borderRadius);
          radii.add(radius);
        }
        radii.add(radius);

        for (final visibleDot in hiker.getAllVisibleDots()) {
          for (int i = 0; i < paths.length; i++) {
            paths[i]
                .addOval(Rect.fromCircle(center: visibleDot, radius: radii[i]));
          }
        }
      } else if (isDashed) {
        final DashedPixelHiker hiker = DashedPixelHiker(
          offsets: offsets,
          segmentValues: polyline.pattern.segments!,
          patternFit: polyline.pattern.patternFit!,
          closePath: false,
          canvasSize: size,
        );

        for (final visibleSegment in hiker.getAllVisibleSegments()) {
          for (final path in paths) {
            path.moveTo(visibleSegment.begin.dx, visibleSegment.begin.dy);
            path.lineTo(visibleSegment.end.dx, visibleSegment.end.dy);
          }
        }
      } else {
        if (offsets.isNotEmpty) {
          for (final path in paths) {
            path.addPolygon(offsets, false);
          }
        }
      }
    }

    drawPaths();
  }

  ui.Gradient _paintGradient(Polyline polyline, List<Offset> offsets) =>
      ui.Gradient.linear(offsets.first, offsets.last, polyline.gradientColors!,
          _getColorsStop(polyline));

  List<double>? _getColorsStop(Polyline polyline) =>
      (polyline.colorsStop != null &&
              polyline.colorsStop!.length == polyline.gradientColors!.length)
          ? polyline.colorsStop
          : _calculateColorsStop(polyline);

  List<double> _calculateColorsStop(Polyline polyline) {
    final colorsStopInterval = 1.0 / polyline.gradientColors!.length;
    return polyline.gradientColors!
        .map((gradientColor) =>
            polyline.gradientColors!.indexOf(gradientColor) *
            colorsStopInterval)
        .toList();
  }

  double _metersToStrokeWidth(
    Offset origin,
    LatLng p0,
    Offset o0,
    double strokeWidthInMeters,
  ) {
    final r = _distance.offset(p0, strokeWidthInMeters, 180);
    final delta = o0 - getOffset(camera, origin, r);
    return delta.distance;
  }

  LatLng _unproject(DoublePoint p0) =>
      camera.crs.projection.unprojectXY(p0.x, p0.y);

  @override
  bool shouldRepaint(_PolylinePainter<R> oldDelegate) =>
      polylines != oldDelegate.polylines ||
      camera != oldDelegate.camera ||
      hitNotifier != oldDelegate.hitNotifier ||
      minimumHitbox != oldDelegate.minimumHitbox;
}

const _distance = Distance();
