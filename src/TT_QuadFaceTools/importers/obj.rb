#-------------------------------------------------------------------------------
#
# Thomas Thomassen
# thomas[at]thomthom[dot]net
#
#-------------------------------------------------------------------------------

require 'TT_QuadFaceTools/importers/mtl'
require 'TT_QuadFaceTools/ui/obj_import_options'
require 'TT_QuadFaceTools/entities'
require 'TT_QuadFaceTools/unit_helper'
require 'TT_QuadFaceTools/vertex_cache'


module TT::Plugins::QuadFaceTools
class ObjImporter < Sketchup::Importer

  include UnitHelper

  IMPORTER_PREF_KEY = "#{PLUGIN_ID}\\Importer\\OBJ".freeze

  SWAP_YZ_TRANSFORM = Geom::Transformation.axes(
      ORIGIN, X_AXIS, Z_AXIS, Y_AXIS.reverse
  ).freeze

  # Encodings most commonly encountered in real-world OBJ files, tried first
  # before falling back to the full Encoding.name_list to reduce retry loops.
  PRIORITY_ENCODINGS = %w[
    Windows-1252 Windows-1251 Windows-1250 Windows-1253 Windows-1254
    Windows-1255 Windows-1256 Windows-1257 GBK GB18030 Big5 Shift_JIS
    EUC-JP EUC-KR KOI8-R ISO-8859-1 ISO-8859-2 ISO-8859-5 ISO-8859-7
    ISO-8859-15
  ].freeze

  class ObjEncodingError < StandardError; end

  attr_accessor :stats

  def initialize(parse_only: false)
    @parse_only = parse_only
    @stats = nil
  end

  # This method is called by SketchUp to determine the description that
  # appears in the File > Import dialog's pull-down list of valid
  # importers.
  #
  # @return [String]
  def description
    "OBJ Files - #{PLUGIN_NAME} (*.obj)"
  end

  # This method is called by SketchUp to determine what file extension
  # is associated with your importer.
  #
  # @return [String]
  def file_extension
    'obj'
  end

  # This method is called by SketchUp to get a unique importer id.
  #
  # @return [String]
  def id
    'com.sketchup.importers.obj_quadfacetools'
  end

  # This method is called by SketchUp to determine if the "Options"
  # button inside the File > Import dialog should be enabled while your
  # importer is selected.
  #
  # @return [Boolean]
  def supports_options?
    true
  end

  # This method is called by SketchUp when the user clicks on the
  # "Options" button inside the File > Import dialog. You can use it to
  # gather and store settings for your importer.
  #
  # @return [Nil]
  def do_options
    options = get_options
    @option_window ||= ObjImportOptions.new { |results|
      process_options(results)
    }
    @option_window.options = options
    @option_window.modal_window.show
    process_options(@option_window.results) if TT::System::PLATFORM_IS_WINDOWS
    nil
  rescue Exception => exception
    ERROR_REPORTER.handle(exception)
  end

  # This method is called by SketchUp after the user has selected a file
  # to import. This is where you do the real work of opening and
  # processing the file.
  #
  # @param [String] filename
  # @param [Boolean] show_summary
  #
  # @return [integer]
  def load_file(filename, show_summary)
    unless File.exist?(filename)
      Sketchup::Importer::ImportFileNotFound
    end
    base_path = File.dirname(filename)
    model = Sketchup.active_model
    options = get_options
    model.start_operation('Import OBJ', true)
    # The base group containing all the imported entities.
    group = model.active_entities.add_group
    group.name = File.basename(filename)
    root_entities = group.entities
    parent_entities = root_entities
    # The current Sketchup::Entities collection new entities should be added to.
    entities = root_entities
    # Material manager for the OBJ file being parsed.
    materials = MtlParser.new(model, base_path)
    # The current material which should be applied to geometry.
    material = nil
    # List of vertices defined for the OBJ file.
    # OBJ files uses 1-based indicies.
    vertex_cache = VertexCache.new
    vertex_cache.index_base = 1
    # A hash with smoothing group numbers mapping to the faces within the same
    # smoothing group.
    smoothing_groups = {}
    # The current smoothing group new faces should be added to unless its Nil.
    smoothing_group = nil
    # Statistics over the imported OBJ data.
    @stats = Statistics.new
    # Pending polygon batches for bulk geometry creation via PolygonMesh.
    # Key: [entities.object_id, material.object_id | nil]
    # Used for faces that need neither UV mapping nor smoothing-group tracking.
    pending_meshes = {}
    Sketchup.status_text = 'Importing OBJ file...'
    # @see http://paulbourke.net/dataformats/obj/
    # @see http://www.martinreddy.net/gfx/3d/OBJ.spec
    # Precompute per-file constants so the hot line-parsing loop avoids
    # repeated method calls and case-statement lookups.
    unit_scale = unit_to_inch_ratio(options[:units])
    swap_yz    = options[:swap_yz]
    custom_encodings = nil
    encoding = 'UTF-8'
    attempts = 0
    begin
    File.open(filename, "r:#{encoding}:UTF-8") { |file|
      file.each_line { |line|
        # Filter out comments.
        next if line.start_with?('#')
        # Parse the line data and extract the line token.
        # split(' ') strips leading/trailing whitespace and handles empty lines.
        begin
          data = line.split(' ')
        rescue ArgumentError => e
          if e.message.include?('invalid byte sequence')
            # Encoding mismatch — outer rescue block will retry with next encoding.
          end
          raise
        end
        next if data.empty?
        token = data.shift
        case token
        when 'v'
          # Read the vertex data.
          raise 'invalid vertex data' if data.size < 3
          x = data[0].to_f * unit_scale
          y = data[1].to_f * unit_scale
          z = data[2].to_f * unit_scale
          if swap_yz
            vertex_cache.add_vertex(x, z, -y)
          else
            vertex_cache.add_vertex(x, y, z)
          end
        when 'vt'
          # Read the vertex texture data.
          # Spec says default is 0.0, but that yield invalid data for SketchUp.
          u = data.x.to_f
          v = (data.y || 1.0).to_f
          w = (data.z || 1.0).to_f
          vertex_cache.add_uvw(u, v, w)
        when 'p'
          # Represent points as construction points.
          data.each { |n|
            v = n.to_i
            point = vertex_cache.get_vertex(v)
            entities.add_cpoint(point) unless @parse_only
            stats.points += 1
          }
        when 'l'
          # Create edges ("lines").
          points = data.map { |triplet|
            v = parse_triplet(triplet)[0]
            vertex_cache.get_vertex(v)
          }
          entities.add_edges(points) unless @parse_only
          stats.edges += (points.size - 1)
          stats.lines += 1
        when 'f'
          # Crease polygon faces.
          points = []
          mapping = []
          data.each { |triplet|
            v, vt = parse_triplet(triplet)
            point = vertex_cache.get_vertex(v)
            if points.include?(point)
              # TODO: Message error back to user without raising error. Need to
              # continue reading file.
              stats.errors += 1
              next
            end
            points << point
            if vt
              uvw = vertex_cache.get_uvw(vt)
              uvw.z = 1.0 if uvw.z == 0.0 # Account for some weird files.
              mapping << point
              mapping << TT::UVQ.normalize(uvw)
            end
          }
          unless @parse_only
            if mapping.empty? && !smoothing_group
              # Fast path: accumulate into a PolygonMesh for bulk creation.
              # Cannot be used when UV mapping or smoothing-group membership is
              # needed, as both require a face object after creation.
              key = [entities.object_id, material&.object_id]
              batch = pending_meshes[key] ||= {
                entities: entities, material: material, polygons: []
              }
              batch[:polygons] << points
            else
              # Standard path: UV mapping or smoothing-group tracking required.
              face = create_face(entities, points, material, mapping)
              if face.nil?
                stats.errors += 1
                next
              end
              if smoothing_group
                smoothing_groups[smoothing_group] ||= []
                smoothing_groups[smoothing_group] << face
              end
            end
          end
          stats.faces += 1
        when 'g'
          # Assuming that objects can contain groups.
          unless @parse_only
            group = parent_entities.add_group
            group.name = data[0] unless data[0].empty?
            entities = group.entities
          end
          stats.objects += 1
        when 'o'
          unless @parse_only
            group = root_entities.add_group
            group.name = data[0] unless data[0].empty?
            entities = group.entities
            parent_entities = entities
          end
          stats.groups += 1
        when 's'
          group_number = data[0] == 'off' ? nil : data[0].to_i
          group_number = nil if group_number == 0
          smoothing_group = group_number
        when 'mtllib'
          loaded = false
          data.each { |library|
            library_file = find_file(library, filename)
            loaded ||= materials.read(library_file)
          }
          if data.size > 1 && !loaded
            # Fall back to using the whole line as the filename. Version 0.8
            # exported MTL files with spaces if the OBJ file had spaces.
            result = line.match(/mtllib\s+(.+)/)
            next unless result
            library = result[1]
            library_file = find_file(library, filename)
              loaded ||= materials.read(library_file)
          end
          raise ObjEncodingError if !loaded && custom_encodings
        when 'usemtl'
          # If we don't get a material from the MtlParser then it probably means
          # it wasn't able to find the materials file. In this case we try to
          # fall back to using currently selected material. UVLayout for
          # instance will generate new OBJ files without MTL files.
          # - Source: SketchUcation user Ithil
          # TODO(thomthom): Maybe expose this behaviour as a user option.
          # material = materials.get(data[0]) || model.materials.current
          material = materials.get(data[0])
          if material.nil?
            materials.load(data[0])
            material = materials.get(data[0])
          end
          if material.nil?
            # TODO: Message error back to user without raising error. Need to
            # continue reading file.
            material = model.materials.current
          end
        else
          # Any other token is either unknown or not supported. No errors is
          # raised as the importer attempt to import what it can.
          # puts "Skipping token: #{token}" # TODO: Consider logging this.
          next
        end
      }
    }
    rescue ArgumentError, ObjEncodingError, EncodingError => error
      if error.is_a?(ArgumentError) && !error.message.include?('invalid byte sequence')
        raise
      end
      # TODO: Log errors. (Allow user to access?)
      if custom_encodings.nil?
        custom_encodings = (PRIORITY_ENCODINGS + Encoding.name_list).uniq
        custom_encodings.delete(encoding)
      end
      raise if custom_encodings.empty?
      encoding = custom_encodings.shift
      attempts += 1
      raise 'MAX ATTEMPTS' if attempts > Encoding.list.size
      retry
    end
    flush_pending_meshes(pending_meshes) unless @parse_only
    apply_smoothing_groups(smoothing_groups)
    model.commit_operation
    Sketchup.status_text = ''
    # Display summary back to the user
    stats.materials = materials.used_materials.size
    stats.smoothing_groups = smoothing_groups.size
    if show_summary
      message = "OBJ Import Results\n"
      message << "\n"
      message << "Points: #{stats.points}\n"
      message << "Lines: #{stats.lines}\n"
      message << "Faces: #{stats.faces}\n"
      message << "Objects: #{stats.objects}\n"
      message << "Groups: #{stats.groups}\n"
      message << "Materials: #{materials.used_materials.size}\n"
      message << "Smoothing Groups: #{stats.smoothing_groups}\n"
      if stats.errors > 0
        message << "\n"
        message << "Errors: #{stats.errors}\n"
      end
      # TODO: Add elapsed time.
      UI.messagebox(message, MB_MULTILINE)
    end
    Sketchup::Importer::ImportSuccess
  rescue Exception => exception
    model.abort_operation
    # Ensure the error is reported.
    ERROR_REPORTER.report(exception)
    # The importer interface have its own way to handle errors, so we don't
    # re-raise. Instead output to console.
    # TODO: Output to $STDERR?
    p exception
    puts exception.backtrace.join("\n")
    Sketchup::Importer::ImportFail
  end

  private

  Statistics = Struct.new(:points, :lines, :faces, :objects, :groups,
      :smoothing_groups, :materials, :edges, :errors) do
    def initialize(*args)
      super(*args)
      each_pair { |key, value|
        send("#{key.to_s}=", 0) if value.nil?
      }
    end
  end

  # Creates all accumulated PolygonMesh batches in bulk.
  # Each batch represents faces that share the same entities context and
  # material and required neither UV mapping nor smoothing-group tracking.
  #
  # @param [Hash] pending_meshes
  # @return [nil]
  def flush_pending_meshes(pending_meshes)
    pending_meshes.each_value { |batch|
      polygons = batch[:polygons]
      # Allocate the mesh with an upper-bound vertex count to avoid rehashing.
      mesh = Geom::PolygonMesh.new(polygons.sum(&:size))
      polygons.each { |pts| mesh.add_polygon(*pts) }
      # smooth_flags = 0: no automatic smoothing; preserve hard edges.
      batch[:entities].add_faces_from_mesh(mesh, 0, batch[:material])
    }
    nil
  end

  # @param [Hash{Integer => Array<Sketchup::Face, QuadFace>}] smoothing_groups
  #
  # @return [Nil]
  def apply_smoothing_groups(smoothing_groups)
    smoothing_groups.values.each { |faces|
      edge_refs = {}
      # Count how many times each edge is used by the faces in the smoothing
      # group.
      faces.each { |face|
        face.edges.each { |edge|
          edge_refs[edge] ||= 0
          edge_refs[edge] += 1
        }
      }
      # Any edge referencing two faces should be smooth. Less and it's at a
      # border, more and it's part of a fork.
      edge_refs.each { |edge, refs|
        next unless refs == 2
        edge.soft = true
        edge.smooth = true
      }
    }
    nil
  end

  # @param [Sketchup::Entities] entities
  # @param [Array<Geom::Point3d>] points
  # @param [Sketchup::Material, Nil] material
  # @param [Array<Geom::Point3d>] mapping
  #
  # @return [Sketchup::Face, QuadFace]
  def create_face(entities, points, material, mapping)
    if TT::Geom3d.planar_points?(points)
      face = entities.add_face(points)
      # Check face orientation. SketchUp might try to adjust the face to
      # a neighbouring face - and this isn't always ideal. For instance,
      # internal faces can easily affect exterior faces like this.
      face.reverse! if face_reversed?(points, face)
      if textured?(material) && !mapping.empty?
        # p ['mapping', material, mapping]
        begin
          face.position_material(material, mapping, true)
          face.position_material(material, mapping, false)
        rescue ArgumentError
          # TODO: Warn user about error. Log to error file.
          face.material = material
          face.back_material = material
        end
      else
        face.material = material
      end
    elsif points.size == 4
      provider = EntitiesProvider.new([], entities)
      face = provider.add_quad(points)
      # TODO: Check face orientation.
      if textured?(material) && !mapping.empty?
        vertices = sort_vertices(face.vertices, points)
        quad_mapping = {}
        vertices.each_with_index { |vertex, i|
          uvw = mapping[(i * 2) + 1]
          quad_mapping[vertex] = uvw
        }
        # p ['quad_mapping', material, quad_mapping]
        begin
          face.uv_set(material, quad_mapping, true)
          face.uv_set(material, quad_mapping, false)
        rescue ArgumentError
          # TODO: Warn user about error.
          face.material = material
          face.back_material = material
        end
      else
        face.material = material
      end
    elsif points.size == 3
      # TODO: Throw custom errors that can be used for more detailed failure
      # messages.
      # TODO: TriangleTooSmall < CreateFaceError
      raise 'triangle is too small'
    elsif points.size < 3
      # TODO: NotEnoughUniquePoints < CreateFaceError
      raise 'polygon with less than three unique vertices'
    else
      # TODO: NgonNotPlanar < CreateFaceError
      raise 'cannot import n-gons which are not planar'
    end
    face
  rescue
    nil
  end

  # @param [Array<Geom::Point3d>] points
  # @param [Sketchup::Face] face
  #
  # @return [Boolean]
  def face_reversed?(points, face)
    vertices = face.outer_loop.vertices
    start_point = points[0]
    start_vertex = vertices.find { |v| v.position == start_point }
    points[1] != vertices[1].position
  end

  # If the given filename isn't found it's assumed to be relative to the
  # second argument provided.
  #
  # @param [String] filename
  # @param [String] relative_to
  #
  # @return [String]
  def find_file(filename, relative_to)
    return File.expand_path(filename) if File.exist?(filename)
    path = File.expand_path(File.dirname(relative_to))
    File.join(path, filename)
  end

  # @param [Sketchup::Material] material
  def textured?(material)
    return false if material.nil?
    material && material.texture
  end

  # @param [Array<String>] data
  #
  # @return [Array<Integer>]
  def parse_triplet(data)
    data.split('/').map { |n| n.empty? ? nil : n.to_i }
  end

  # @param [Array<Sketchup::Vertex>] vertices
  # @param [Array<Geom::Point3d>] order_by_points
  #
  # @return [Array<Sketchup::Vertex>]
  def sort_vertices(vertices, order_by_points)
    order_by_points.map { |point|
      vertex = vertices.find { |vertex| vertex.position == point }
      # TODO: Custom error. (?)
      raise 'unable to sort vertices' if vertex.nil?
      vertex
    }
  end

  # @return [Hash{Symbol => Object}]
  def default_options
    {
      :units   => UNIT_MODEL,
      :swap_yz => true
    }
  end

  # @return [Hash{Symbol => Object}]
  def get_options
    options = {}
    default_options.each { |key, default|
      value = Sketchup.read_default(IMPORTER_PREF_KEY, key.to_s, default)
      options[key] = value
    }
    options
  end

  # @param [Hash{Symbol => Object}] results
  #
  # @return [Nil]
  def process_options(results)
    return nil if results.nil? # In case Options were cancelled.
    # Save the options for next time.
    results.each { |key, value|
      Sketchup.write_default(IMPORTER_PREF_KEY, key.to_s, value)
    }
    nil
  end

end # class
end # module
