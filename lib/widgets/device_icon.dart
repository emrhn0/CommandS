import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../models/models.dart';

/// The logo of a [DeviceKind], in its maker's colours, sized like a 16 px
/// list icon. Cisco's mark is a wide row of bars, so it spills a little to
/// both sides rather than shrinking to a sliver; the space it takes in the
/// layout stays square, so names still line up.
class DeviceIcon extends StatelessWidget {
  const DeviceIcon(this.kind, {super.key, this.size = 16});

  final DeviceKind kind;
  final double size;

  /// The device a connection shows: an RDP session is always Windows.
  static DeviceKind? of(SavedConnection conn) =>
      conn.protocol == ConnectionProtocol.rdp ? DeviceKind.windows : conn.device;

  @override
  Widget build(BuildContext context) {
    final width = kind == DeviceKind.cisco ? size * 1.375 : size;
    return SizedBox.square(
      dimension: size,
      child: OverflowBox(
        minWidth: width,
        maxWidth: width,
        child: SvgPicture.asset(
          'assets/devices/${kind.name}.svg',
          key: ValueKey('device-${kind.name}'),
          width: width,
          height: size,
        ),
      ),
    );
  }
}
