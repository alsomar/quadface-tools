#-------------------------------------------------------------------------------
#
# Thomas Thomassen
# thomas[at]thomthom[dot]net
#
#-------------------------------------------------------------------------------

require 'testup/testcase'


class TC_LoopOffset < TestUp::TestCase

  QFT = TT::Plugins::QuadFaceTools


  def setup
    start_with_empty_model
  end

  def teardown
    # ...
  end


  # ======= Helpers =======

  # Creates a single 9x9 quad face on the XY plane.
  def create_test_face
    points = [
      Geom::Point3d.new(0, 0, 0),
      Geom::Point3d.new(9, 0, 0),
      Geom::Point3d.new(9, 9, 0),
      Geom::Point3d.new(0, 9, 0),
    ]
    Sketchup.active_model.active_entities.add_face(points)
  end

  # Creates n quads side-by-side along the X axis (each size x size).
  # Returns the faces sorted left-to-right by centroid X so index 0 is the
  # leftmost quad.
  def create_strip(n, size = 1.m)
    entities = Sketchup.active_model.active_entities
    n.times { |col|
      pts = [
        Geom::Point3d.new( col      * size, 0,    0),
        Geom::Point3d.new((col + 1) * size, 0,    0),
        Geom::Point3d.new((col + 1) * size, size, 0),
        Geom::Point3d.new( col      * size, size, 0),
      ]
      entities.add_face(pts)
    }
    entities.grep(Sketchup::Face).sort_by { |f| f.bounds.center.x }
  end

  # Returns the edge of +face+ whose both endpoints lie at y == 0 (the bottom
  # edge of a strip quad).
  def bottom_edge(face)
    face.outer_loop.edges.find { |e|
      e.vertices.all? { |v| v.position.y == 0 }
    }
  end


  # ======= Tests =======

  # Single quad: forward traversal yields 1 position (the cross-edge on the
  # right side of the quad). The `<=` condition in calculate ensures the
  # reverse endpoint (left boundary) is always appended → 2 total.
  def test_positions_one_edge
    face = create_test_face
    provider = QFT::EntitiesProvider.new(face.parent.entities)
    offset = QFT::LoopOffset.new(provider)
    offset.loop = face.outer_loop.edges.take(1)
    offset.origin = face.outer_loop.vertices.first.position
    offset.start_edge = face.outer_loop.edges.first
    offset.start_quad = face
    offset.distance = 3
    assert(offset.ready?, 'loop not ready')
    assert_equal(2, offset.positions.size)
  end

  # 2-quad horizontal strip: forward traversal crosses the shared internal edge
  # and the far right boundary (2 positions), then the reverse endpoint (left
  # boundary) adds 1 more → 3 positions total.
  def test_positions_two_edges
    faces = create_strip(2)
    loop_edges = faces.map { |f| bottom_edge(f) }
    provider = QFT::EntitiesProvider.new(Sketchup.active_model.active_entities)
    offset = QFT::LoopOffset.new(provider)
    offset.loop = loop_edges
    offset.origin = loop_edges.first.vertices.first.position
    offset.start_edge = loop_edges.first
    offset.start_quad = faces.first
    offset.distance = 3
    assert(offset.ready?, 'loop not ready')
    assert_equal(3, offset.positions.size)
  end

  # 4-quad horizontal strip: forward traversal crosses 3 internal shared edges
  # plus the far right boundary (4 positions), then the reverse endpoint adds
  # 1 more → 5 positions total.
  def test_positions_four_edges
    faces = create_strip(4)
    loop_edges = faces.map { |f| bottom_edge(f) }
    provider = QFT::EntitiesProvider.new(Sketchup.active_model.active_entities)
    offset = QFT::LoopOffset.new(provider)
    offset.loop = loop_edges
    offset.origin = loop_edges.first.vertices.first.position
    offset.start_edge = loop_edges.first
    offset.start_quad = faces.first
    offset.distance = 3
    assert(offset.ready?, 'loop not ready')
    assert_equal(5, offset.positions.size)
  end

end # class
