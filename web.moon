
http = require "lapis.nginx.http"
db = require "lapis.nginx.postgres"

lapis = require "lapis.init"
bucket = require "secret.storage_bucket"

persist = require "luarocks.persist"

import respond_to from require "lapis.application"
import escape_pattern from require "lapis.util"
import Users, Modules, Versions, Rocks, Manifests from require "models"

import concat, insert from table

require "moon"

parse_rockspec = (text) ->
  fn = loadstring text, rock
  return nil, "Failed to parse rockspec" unless fn
  spec = {}
  setfenv fn, spec
  return nil, "Failed to eval rockspec" unless pcall(fn)

  unless spec.package
    return nil, "Invalid rockspec (missing package)"

  unless spec.version
    return nil, "Invalid rockspec (missing version)"

  spec

filename_for_rockspec = (spec) ->
  "#{spec.package}-#{spec.version}.rockspec"

parse_rock_fname = (module_name, fname) ->
  version, arch = fname\match "^#{escape_pattern(module_name)}%-(.-)%.([^.]+)%.rock$"
  unless version
    nil, "Filename must be in format `#{module_name}-VERSION.ARCH.rock`"

  { :version, :arch }


default_table = ->
  setmetatable {}, __index: (key) =>
    with t = {} do @[key] = t

render_manifest = (modules) =>
  mod_ids = [mod.id for mod in *modules]

  repository = {}
  if next mod_ids
    mod_ids = concat mod_ids, ", "
    versions = Versions\select "where module_id in (#{mod_ids})"

    module_to_versions = default_table!
    version_to_rocks = default_table!

    version_ids = [v.id for v in *versions]
    if next version_ids
      version_ids = concat version_ids, ", "
      rocks = Rocks\select "where version_id in (#{version_ids})"
      for rock in *rocks
        insert version_to_rocks[rock.version_id], rock

    for v in *versions
      insert module_to_versions[v.module_id], v

    for mod in *modules
      vtbl = {}

      for v in *module_to_versions[mod.id]
        rtbl = {}
        insert rtbl, arch: "rockspec"
        for rock in *version_to_rocks[v.id]
          insert rtbl, arch: rock.arch

        vtbl[v.version_name] = rtbl

      repository[mod.name] = vtbl

  commands = {}
  modules = {}

  @res.headers["Content-type"] = "text/x-lua"
  layout: false, persist.save_from_table_to_string {
    :repository, :commands, :modules
  }

lapis.serve class extends lapis.Application
  layout: require "views.layout"

  @before_filter =>
    @current_user = Users\read_session @

  "/db/make": =>
    schema = require "schema"
    schema.make_schema!
    Manifests\create "root", true
    json: { status: "ok" }

  [modules: "/modules"]: =>
    @modules = Modules\select "order by name asc"
    Users\include_in @modules, "user_id"
    render: true

  [upload_rockspec: "/upload"]: respond_to {
    GET: => render: true
    POST: =>
      assert @current_user, "Must be logged in"

      file = assert @params.rockspec_file or false, "Missing rockspec"
      spec = assert parse_rockspec file.content
      mod = assert Modules\create spec, @current_user

      key = "#{@current_user.id}/#{filename_for_rockspec spec}"
      out = bucket\put_file_string file.content, {
        :key, mimetype: "text/x-rockspec"
      }

      unless out == 200
        mod\delete!
        error "Failed to upload rockspec"

      version = assert Versions\create mod, spec, key

      mod.current_version_id = version.id
      mod\update "current_version_id"

      { redirect_to: @url_for "module", user: @current_user.slug, module: mod.name }
  }

  [index: "/"]: => render: true

  [root_manifest: "/manifest"]: =>
    all_modules = Modules\select!
    render_manifest @, all_modules

  "/manifests/:user": => redirect_to: @url_for("user_manifest", user: @params.user)

  [user_manifest: "/manifests/:user/manifest"]: =>
    user = assert Users\find(slug: @params.user), "Invalid user"
    render_manifest @, user\all_modules!

  [user_profile: "/modules/:user"]: =>
    @user = assert Users\find(slug: @params.user), "Invalid user"
    @modules = Modules\select "where user_id = ? order by name asc", @user.id
    for mod in *@modules
      mod.user = @user

    render: true

  load_module = =>
    @user = assert Users\find(slug: @params.user), "Invalid user"
    @module = assert Modules\find(user_id: @user.id, name: @params.module), "Invalid module"
    if @params.version
      @version = assert Versions\find({
        module_id: @module.id
        version_name: @params.version
      }), "Invalid version"

  [module: "/modules/:user/:module"]: =>
    load_module @
    @versions = Versions\select "where module_id = ? order by created_at desc", @module.id

    for v in *@versions
      if v.id == @module.current_version_id
        @current_version = v

    render: true

  [module_version: "/modules/:user/:module/:version"]: =>
    load_module @
    @rocks = Rocks\select "where version_id = ? order by arch asc", @version.id

    render: true

  [upload_rock: "/modules/:user/:module/:version/upload"]: respond_to {
    GET: =>
      load_module @
      unless @module\user_can_edit @current_user
        error "Don't have permission to edit module"
      render: true

    POST: =>
      load_module @
      unless @module\user_can_edit @current_user
        error "Don't have permission to edit module"

      file = assert @params.rock_file or false, "Missing rock"
      rock_info = assert parse_rock_fname @module.name, file.filename

      if rock_info.version != @version.version_name
        error "Rock doesn't match version #{@version.version_name}"

      key = "#{@current_user.id}/#{file.filename}"
      out = bucket\put_file_string file.content, {
        :key, mimetype: "application/x-rock"
      }

      unless out == 200
        error "Failed to upload rock"

      Rocks\create @version, rock_info.arch, key
      redirect_to: @url_for "module_version", @
  }

  -- need a way to combine the routes from other applications?
  [user_login: "/login"]: respond_to {
    GET: => render: true
    POST: =>
      user, err = Users\login @params.username, @params.password

      if user
        user\write_session @
        return redirect_to: "/"

      @html -> text err
  }

  [user_register: "/register"]: respond_to {
    GET: => render: true
    POST: =>
      require "moon"
      @html ->
        text "dump:"
        pre moon.dump @params
  }

  -- TODO: make this post
  [user_logout: "/logout"]: =>
    @session.user = false
    redirect_to: "/"

  --

  [files: "/files"]: =>
    @html ->
      h2 "Files"
      ol ->
        for thing in *bucket\list!
          li ->
            a href: bucket\file_url(thing.key), thing.key
            text " (#{thing.size}) #{thing.last_modified}"

  [dump: "/dump"]: =>
    require "moon"
    @html ->
      text "#{@req.cmd_mth}:"
      pre moon.dump @params

