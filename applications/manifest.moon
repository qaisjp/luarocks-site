-- app responsible for rendering manifests

lapis = require "lapis"

import
  assert_error
  capture_errors
  from require "lapis.application"

import assert_valid from require "lapis.validate"

import
  Manifests
  Modules
  Users
  Versions
  Rocks
  from require "models"

import build_manifest, preload_modules, serve_lua_table from require "helpers.manifests"
import get_all_pages from require "helpers.models"
import capture_errors_404, assert_page from require "helpers.app"
import zipped_file from require "helpers.zip"

import preload from require "lapis.db.model"

config = require("lapis.config").get!

zipable = (fn) ->
  =>
    @write fn @

    return unless @format == "zip"
    return unless (@options.status or 200) == 200
    return unless @req.cmd_mth == "GET"

    fname = "manifest"
    if @version
      fname ..= "-#{@version}"

    @options.content_type = "application/zip"
    @res.content = zipped_file fname, table.concat @buffer
    @buffer = {}
    nil

serve_manifest = capture_errors_404 =>
  if @params.a or @params.b
    @params.version = "#{@params.a}.#{@params.b}"

  assert_valid @params, {
    {"format", optional: true, one_of: {"json", "zip"}}
    {"version", optional: true, one_of: {"5.1", "5.2", "5.3"}}
  }

  @format = @params.format
  @version = @params.version

  -- find what we are fetching modules from
  thing = if @params.manifest
    assert_error Manifests\find_by_name @params.manifest
  else
    Manifests\root!

  if thing.__class == Manifests
    date = require "date"
    @res\add_header "Last-Modified", date(thing.updated_at)\fmt "${http}"

    -- on HEAD just return last modified
    if @req.method == "HEAD"
      return { layout: false }

  if @req.method != "GET"
    return {
      layout: false
      status: 405
    }, "Incorrect method"

  -- get the modules
  pager = thing\find_modules {
    fields: "id, name"
    per_page: 50
    prepare_results: preload_modules
  }

  modules = get_all_pages pager
  manifest = build_manifest modules, @version, @development

  if @format == "json"
    json: manifest
  else
    serve_lua_table @, manifest

is_dev = (fn) ->
  =>
    @development = true
    fn @

is_stable = (fn) ->
  =>
    @development = false
    fn @

class MoonRocksManifest extends lapis.Application
  [root_manifest: "/manifest(-:a.:b)(.:format)"]: zipable is_stable serve_manifest
  [root_manifest_dev: "/dev/manifest(-:a.:b)(.:format)"]: zipable is_dev serve_manifest
  [user_manifest: "/manifests/:manifest/manifest(-:a.:b)(.:format)"]: zipable serve_manifest

  "/dev": => redirect_to: @url_for "root_manifest_dev"
  "/manifests/:manifest": =>
    redirect_to: @url_for("user_manifest", manifest: @params.manifest)

  [manifests: "/manifests"]: capture_errors_404 =>
    @title = "All manifests"
    import ManifestAdmins from require "models"

    assert_page @

    @pager = Manifests\paginated [[
      where mirror_user_id is null
      order by id asc
    ]], {
      per_page: 50
      prepare_results: (manifests) ->
        preload manifests, admins: "user"
        manifests
    }

    @manifests = @pager\get_page @page
    render: true
