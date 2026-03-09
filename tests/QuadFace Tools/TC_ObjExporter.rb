#-------------------------------------------------------------------------------
#
# Thomas Thomassen
# thomas[at]thomthom[dot]net
#
#-------------------------------------------------------------------------------

require 'testup/testcase'


class TC_ObjExporter < TestUp::TestCase

  QFT = TT::Plugins::QuadFaceTools


  def setup
    start_with_empty_model
    @temp_dir = File.join(Sketchup.temp_dir, 'TC_ObjExporter')
    Dir.mkdir(@temp_dir) unless File.exist?(@temp_dir)
  end

  def teardown
    # Clean up temp files.
    Dir.glob(File.join(@temp_dir, '*')).each { |f| File.delete(f) rescue nil }
  end


  # ======= Helpers =======

  def temp_obj_path
    File.join(@temp_dir, 'test_export.obj')
  end

  # Creates a flat square face on the XY plane. Size in inches.
  def create_single_quad(size = 1.m)
    pts = [
      Geom::Point3d.new(0,    0,    0),
      Geom::Point3d.new(size, 0,    0),
      Geom::Point3d.new(size, size, 0),
      Geom::Point3d.new(0,    size, 0),
    ]
    Sketchup.active_model.active_entities.add_face(pts)
  end

  # Creates a cols x rows grid of touching quads (shared edges).
  # Returns the number of faces added.
  def create_grid(cols, rows, size = 1.m)
    entities = Sketchup.active_model.active_entities
    rows.times { |row|
      cols.times { |col|
        pts = [
          Geom::Point3d.new( col      * size,  row      * size, 0),
          Geom::Point3d.new((col + 1) * size,  row      * size, 0),
          Geom::Point3d.new((col + 1) * size, (row + 1) * size, 0),
          Geom::Point3d.new( col      * size, (row + 1) * size, 0),
        ]
        entities.add_face(pts)
      }
    }
    cols * rows
  end

  def do_export(options = {})
    exporter = QFT::ExporterOBJ.new
    exporter.export(temp_obj_path, options)
    temp_obj_path
  end

  def read_obj(path)
    File.read(path, encoding: 'utf-8')
  end

  # Returns all lines starting with the given token (e.g. 'v ', 'f ', 'vt ').
  def obj_lines(content, token)
    content.lines.select { |l| l.start_with?(token) }
  end


  # ======= Correctness tests =======

  def test_export_single_face_vertex_count
    create_single_quad
    content = read_obj(do_export(units: QFT::ExporterOBJ::UNIT_METERS, swap_yz: false, texture_maps: false))
    assert_equal(4, obj_lines(content, 'v ').size, 'Expected 4 vertex lines')
  end

  def test_export_single_face_polygon_count
    create_single_quad
    content = read_obj(do_export(units: QFT::ExporterOBJ::UNIT_METERS, swap_yz: false, texture_maps: false))
    assert_equal(1, obj_lines(content, 'f ').size, 'Expected 1 face line')
  end

  def test_export_face_indices_are_one_based
    create_single_quad
    content = read_obj(do_export(units: QFT::ExporterOBJ::UNIT_METERS, swap_yz: false, texture_maps: false))
    f_line = obj_lines(content, 'f ').first
    indices = f_line.split[1..].map(&:to_i)
    assert(indices.all? { |i| i >= 1 }, 'All face indices must be >= 1 (1-based)')
    assert_equal(4, indices.size, 'Quad face must reference 4 vertices')
  end

  def test_export_unit_meters_scale
    create_single_quad(1.m) # 1 meter square (stored as inches internally)
    content = read_obj(do_export(units: QFT::ExporterOBJ::UNIT_METERS, swap_yz: false, texture_maps: false))
    v_lines = obj_lines(content, 'v ')
    xs = v_lines.map { |l| l.split[1].to_f }.uniq.sort
    # Expect coords 0.0 and 1.0 (meters)
    assert_in_delta(0.0, xs.min, 1e-6, 'Min X coord should be 0 meters')
    assert_in_delta(1.0, xs.max, 1e-4, 'Max X coord should be 1 meter')
  end

  def test_export_unit_millimeters_scale
    create_single_quad(1.m) # 1 meter square
    content = read_obj(do_export(units: QFT::ExporterOBJ::UNIT_MILLIMETERS, swap_yz: false, texture_maps: false))
    v_lines = obj_lines(content, 'v ')
    xs = v_lines.map { |l| l.split[1].to_f }.uniq.sort
    assert_in_delta(0.0,    xs.min, 1e-3, 'Min X coord should be 0 mm')
    assert_in_delta(1000.0, xs.max, 0.1,  'Max X coord should be 1000 mm')
  end

  def test_export_swap_yz_z_becomes_y
    create_single_quad # face on XY plane -> Z=0 in SketchUp
    content = read_obj(do_export(units: QFT::ExporterOBJ::UNIT_METERS, swap_yz: true, texture_maps: false))
    v_lines = obj_lines(content, 'v ')
    # After YZ swap a point (x, y, 0) in SU becomes (x, 0, y) in OBJ.
    # The Y column (index 2) should be 0 for all vertices.
    ys = v_lines.map { |l| l.split[2].to_f }.uniq
    assert_equal([0.0], ys, 'With swap_yz all OBJ Y coords should be 0 for a ground-plane face')
  end

  def test_export_no_swap_yz_preserves_z
    create_single_quad # face on XY plane -> Z=0
    content = read_obj(do_export(units: QFT::ExporterOBJ::UNIT_METERS, swap_yz: false, texture_maps: false))
    v_lines = obj_lines(content, 'v ')
    zs = v_lines.map { |l| l.split[3].to_f }.uniq
    assert_equal([0.0], zs, 'Without swap_yz OBJ Z coords should be 0 for a ground-plane face')
  end

  def test_export_references_mtllib
    create_single_quad
    content = read_obj(do_export(units: QFT::ExporterOBJ::UNIT_METERS, swap_yz: false, texture_maps: false))
    assert(content.include?('mtllib '), 'OBJ file must reference a material library')
  end

  def test_export_mtllib_no_spaces_in_name
    create_single_quad
    content = read_obj(do_export(units: QFT::ExporterOBJ::UNIT_METERS, swap_yz: false, texture_maps: false))
    mtllib_line = content.lines.find { |l| l.start_with?('mtllib ') }
    mtl_name = mtllib_line.split(' ', 2).last.strip
    refute(mtl_name.include?(' '), "MTL filename must not contain spaces, got: #{mtl_name}")
  end

  def test_export_grid_vertex_count
    n = create_grid(4, 4) # 4x4 = 16 quads, grid shares vertices
    content = read_obj(do_export(units: QFT::ExporterOBJ::UNIT_METERS, swap_yz: false, texture_maps: false))
    # A 4x4 grid has (4+1)*(4+1) = 25 unique vertices
    assert_equal(25, obj_lines(content, 'v ').size, 'Expected 25 unique vertices for 4x4 grid')
  end

  def test_export_grid_face_count
    create_grid(4, 4) # 16 quad faces
    content = read_obj(do_export(units: QFT::ExporterOBJ::UNIT_METERS, swap_yz: false, texture_maps: false))
    assert_equal(16, obj_lines(content, 'f ').size, 'Expected 16 face lines for 4x4 grid')
  end

  def test_export_no_uv_lines_without_texture
    create_single_quad
    content = read_obj(do_export(units: QFT::ExporterOBJ::UNIT_METERS, swap_yz: false, texture_maps: false))
    assert_equal(0, obj_lines(content, 'vt ').size, 'No UV lines expected when texture_maps is false')
  end

  def test_export_group_by_objects
    create_single_quad
    content = read_obj(do_export(
      units: QFT::ExporterOBJ::UNIT_METERS,
      swap_yz: false,
      texture_maps: false,
      group_type: QFT::ExporterOBJ::GROUP_BY_OBJECTS,
    ))
    assert(content.include?("\no "), 'Expected an object group line (o) for GROUP_BY_OBJECTS')
  end

  def test_export_group_by_groups
    create_single_quad
    content = read_obj(do_export(
      units: QFT::ExporterOBJ::UNIT_METERS,
      swap_yz: false,
      texture_maps: false,
      group_type: QFT::ExporterOBJ::GROUP_BY_GROUPS,
    ))
    assert(content.include?("\ng "), 'Expected a named group line (g) for GROUP_BY_GROUPS')
  end


  # Creates a regular pentagon on the XY plane.
  def create_pentagon(radius = 1.m)
    pts = (0...5).map { |i|
      angle = 2 * Math::PI * i / 5
      Geom::Point3d.new(radius * Math.cos(angle), radius * Math.sin(angle), 0)
    }
    Sketchup.active_model.active_entities.add_face(pts)
  end

  def test_export_triangulate_off_quad
    # With triangulation disabled (default), a quad exports as one f line with 4 indices.
    create_single_quad
    content = read_obj(do_export(
      units: QFT::ExporterOBJ::UNIT_METERS, swap_yz: false,
      texture_maps: false, triangulate: false
    ))
    f_lines = obj_lines(content, 'f ')
    assert_equal(1, f_lines.size, 'Expected 1 face line for untriangulated quad')
    assert_equal(4, f_lines.first.split.size - 1, 'Quad face must reference 4 vertices')
  end

  def test_export_triangulate_on_quad
    # Quads (4 verts) are left intact even when triangulation is enabled.
    # Only n-gons (5+ verts) are triangulated.
    create_single_quad
    content = read_obj(do_export(
      units: QFT::ExporterOBJ::UNIT_METERS, swap_yz: false,
      texture_maps: false, triangulate: true
    ))
    f_lines = obj_lines(content, 'f ')
    assert_equal(1, f_lines.size, 'Quad must not be split when triangulate is enabled')
    assert_equal(4, f_lines.first.split.size - 1, 'Quad face must still reference 4 vertices')
  end

  def test_export_triangulate_on_ngon
    # With triangulation enabled, a pentagon (5 verts) produces n-2 = 3 triangles.
    create_pentagon
    content = read_obj(do_export(
      units: QFT::ExporterOBJ::UNIT_METERS, swap_yz: false,
      texture_maps: false, triangulate: true
    ))
    f_lines = obj_lines(content, 'f ')
    assert_equal(3, f_lines.size, 'Pentagon should triangulate into 3 faces')
    f_lines.each { |line|
      assert_equal(3, line.split.size - 1, 'Each triangle must reference exactly 3 vertices')
    }
  end


  # ======= Performance benchmarks =======
  # These tests measure duration but only assert a generous upper bound.
  # Run them to compare timings before/after optimisation changes.

  def test_benchmark_export_100_faces
    create_grid(10, 10) # 100 quads
    t0 = Time.now
    do_export(units: QFT::ExporterOBJ::UNIT_METERS, swap_yz: true, texture_maps: false)
    elapsed = Time.now - t0
    puts format("\n  [benchmark] 100 quads export: %.1f ms", elapsed * 1000)
    assert(elapsed < 30.0, "Export 100 quads took too long: #{elapsed.round(2)}s")
  end

  def test_benchmark_export_1000_faces
    create_grid(40, 25) # 1000 quads
    t0 = Time.now
    do_export(units: QFT::ExporterOBJ::UNIT_METERS, swap_yz: true, texture_maps: false)
    elapsed = Time.now - t0
    puts format("\n  [benchmark] 1000 quads export: %.1f ms", elapsed * 1000)
    assert(elapsed < 60.0, "Export 1000 quads took too long: #{elapsed.round(2)}s")
  end

  def test_benchmark_export_2500_faces
    create_grid(50, 50) # 2500 quads
    t0 = Time.now
    do_export(units: QFT::ExporterOBJ::UNIT_METERS, swap_yz: true, texture_maps: false)
    elapsed = Time.now - t0
    puts format("\n  [benchmark] 2500 quads export: %.1f ms", elapsed * 1000)
    assert(elapsed < 120.0, "Export 2500 quads took too long: #{elapsed.round(2)}s")
  end

end # class
