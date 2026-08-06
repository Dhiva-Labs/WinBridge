import 'package:winbridge/winbridge.dart';

/// A toolchain that claims the project types it was given and builds whatever
/// [onBuild] says.
class FakeToolchain implements Toolchain {
  FakeToolchain({
    required this.id,
    required Set<ProjectType> handles,
    this.description = 'fake toolchain',
    List<ToolRequirement> requires = const [],
    Future<BuildResult> Function(BuildRequest request)? onBuild,
  })  : _handles = handles,
        _requires = requires,
        _onBuild = onBuild;

  @override
  final String id;

  @override
  final String description;

  final Set<ProjectType> _handles;
  final List<ToolRequirement> _requires;
  final Future<BuildResult> Function(BuildRequest request)? _onBuild;

  /// Requests this toolchain was asked to build, in order.
  final requests = <BuildRequest>[];

  @override
  bool canHandle(Project project) => _handles.contains(project.type);

  @override
  List<ToolRequirement> requirements() => _requires;

  @override
  Future<BuildResult> build(BuildRequest request) async {
    requests.add(request);
    final build = _onBuild;
    if (build == null) {
      return const BuildResult.failure('fake toolchain does not build');
    }
    return build(request);
  }
}

Project fakeProject(ProjectType type, {String root = '/tmp/fake-project'}) =>
    Project(
      root: root,
      type: type,
      name: 'fake',
      evidence: [
        DetectionEvidence(type: type, file: 'marker', reason: 'fake'),
      ],
    );
