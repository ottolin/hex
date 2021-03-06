defmodule Hex.RemoteConverger do
  @moduledoc false

  @behaviour Mix.RemoteConverger

  alias Hex.Registry

  def remote?(dep) do
    !!dep.opts[:hex]
  end

  def converge(deps, lock) do
    Hex.start
    Hex.Utils.ensure_registry!()
    Hex.Registry.open!(Hex.Registry.ETS)
    verify_lock(lock)

    # We cannot use given lock here, because all deps that are being
    # converged have been removed from the lock by Mix
    # We need the old lock to get the children of Hex packages
    old_lock = Mix.Dep.Lock.read

    locked    = prepare_locked(lock, old_lock, deps)
    top_level = Hex.Mix.top_level(deps)
    flat_deps = Hex.Mix.flatten_deps(deps, top_level)
    reqs      = Hex.Mix.deps_to_requests(flat_deps)

    check_deps(deps, top_level)
    check_input(reqs, locked)

    deps      = Hex.Mix.prepare_deps(deps)
    top_level = Enum.map(top_level, &Atom.to_string/1)

    Hex.Shell.info "Running dependency resolution"

    case Hex.Resolver.resolve(reqs, deps, top_level, locked) do
      {:ok, resolved} ->
        print_success(resolved, locked)
        verify_resolved(resolved, old_lock)
        new_lock = Hex.Mix.to_lock(resolved)
        Hex.SCM.prefetch(new_lock)
        Map.merge(lock, new_lock)
      {:error, message} ->
        resolver_failed(message)
    end
  after
    Hex.Registry.pdict_clean
  end

  defp resolver_failed(message) do
    Hex.Shell.info "\n" <> message

    Mix.raise "Hex dependency resolution failed, relax the version " <>
              "requirements of your dependencies or unlock them (by " <>
              "using mix deps.update or mix deps.unlock). If you are " <>
              "unable to resolve the conflicts you can try overriding " <>
              "with {:dependency, \"~> 1.0\", override: true}"
  end

  def deps(%Mix.Dep{app: app}, lock) do
    case Hex.Utils.lock(lock[app]) do
      [:hex, name, version, _checksum, _managers, nil] ->
        Hex.Utils.ensure_registry!(fetch: false)
        get_deps(name, version)
      [:hex, _name, _version, _checksum, _managers, deps] ->
        deps
      _ ->
        []
    end
  after
    Hex.Registry.pdict_clean
  end

  defp get_deps(name, version) do
    name = Atom.to_string(name)
    deps = try_get_deps(name, version)

    for {name, app, req, optional} <- deps do
      app = String.to_atom(app)
      opts = [optional: optional, hex: String.to_atom(name)]

      # Support old packages where requirement could be missing
      if req do
        {app, req, opts}
      else
        {app, opts}
      end
    end
  end

  defp try_get_deps(name, version) do
    if deps = Registry.get_deps(name, version) do
      deps
    else
      Hex.Utils.ensure_registry!()
      Registry.get_deps(name, version) || []
    end
  end

  defp check_deps(deps, top_level) do
    Enum.each(deps, fn dep ->
      if dep.app in top_level and dep.scm == Hex.SCM and is_nil(dep.requirement) do
        Hex.Shell.warn "#{dep.app} is missing its version requirement, " <>
                       "use \">= 0.0.0\" if it should match any version"
      end
    end)
  end

  defp check_input(reqs, locked) do
    Enum.each(reqs, fn {name, _app, req, from} ->
      check_package_req(name, req, from)
    end)

    Enum.each(locked, fn {name, _app, req} ->
      check_package_req(name, req, "mix.lock")
    end)
  end

  defp check_package_req(name, req, from) do
    if Registry.get_versions(name) do
      if req != nil and Hex.Version.parse_requirement(req) == :error do
        Mix.raise "Required version #{inspect req} for package #{name} is incorrectly specified (from: #{from})"
      end
    else
      Mix.raise "No package with name #{name} (from: #{from}) in registry"
    end
  end

  defp print_success(resolved, locked) do
    locked = Enum.map(locked, &elem(&1, 0))
    resolved = Enum.into(resolved, %{}, fn {name, _app, version} -> {name, version} end)
    resolved = Map.drop(resolved, locked)

    if Map.size(resolved) != 0 do
      Hex.Shell.info "Dependency resolution completed"
      resolved = Enum.sort(resolved)
      Enum.each(resolved, fn {name, version} ->
        Hex.Shell.info "  #{name}: #{version}"
      end)
    end
  end

  defp verify_resolved(resolved, lock) do
    Enum.each(resolved, fn {name, app, version} ->
      atom_name = String.to_atom(name)

      case Hex.Utils.lock(lock[String.to_atom(app)]) do
        [:hex, ^atom_name, ^version, checksum, _managers, deps] ->
          registry_checksum = Hex.Registry.get_checksum(name, version)

          if checksum && Base.decode16!(checksum, case: :lower) != Base.decode16!(registry_checksum),
            do: Mix.raise "Registry checksum mismatch against lock (#{name} #{version})"

          if deps do
            deps =
              Enum.map(deps, fn {app, req, opts} ->
                {Atom.to_string(opts[:hex]), Atom.to_string(app), req, !!opts[:optional]}
              end)

            if Enum.sort(deps) != Enum.sort(Hex.Registry.get_deps(name, version)),
              do: Mix.raise "Registry dependencies mismatch against lock (#{name} #{version})"
          end
        _ ->
          :ok
      end
    end)
  end

  defp verify_lock(lock) do
    Enum.each(lock, fn {_app, info} ->
      case Hex.Utils.lock(info) do
        [:hex, name, version, _checksum, _managers, _deps] ->
          verify_dep(Atom.to_string(name), version)
        _ ->
          :ok
      end
    end)
  end

  defp verify_dep(app, version) do
    if versions = Registry.get_versions(app) do
      unless version in versions do
        Mix.raise "Unknown package version #{app} #{version} in lockfile"
      end
    else
      Mix.raise "Unknown package #{app} in lockfile"
    end
  end

  defp with_children(apps, lock) do
    [apps, do_with_children(apps, lock)]
    |> List.flatten
  end

  defp do_with_children(names, lock) do
    Enum.map(names, fn name ->
      case Hex.Utils.lock(lock[String.to_atom(name)]) do
        [:hex, name, version, _checksum, _managers, nil] ->
          # Do not error on bad data in the old lock because we should just
          # fix it automatically
          if deps = Registry.get_deps(Atom.to_string(name), version) do
            apps = Enum.map(deps, &elem(&1, 0))
            [apps, do_with_children(apps, lock)]
          else
            []
          end
        [:hex, _name, _version, _checksum, _managers, deps] ->
          apps = Enum.map(deps, &Atom.to_string(elem(&1, 0)))
          [apps, do_with_children(apps, lock)]
        _ ->
          []
      end
    end)
  end

  defp prepare_locked(lock, old_lock, deps) do
    # Remove dependencies from the lock if:
    # 1. They are defined as git or path in mix.exs
    # 2. If the requirement in mix.exs does not match the locked version
    # 3. If it's a child of another Hex package being unlocked/updated

    unlock =
      Enum.filter_map(deps, fn
        %Mix.Dep{scm: Hex.SCM, app: app, requirement: req, opts: opts} ->
          # Make sure to handle deps that were previously locked as Git
          case Hex.Utils.lock(old_lock[app]) do
            [:hex, name, version, _checksum, _managers, _deps] ->
              req && !Hex.Version.match?(version, req) && name == opts[:hex]
            _ ->
              true
          end

        %Mix.Dep{} ->
          true
      end, &Atom.to_string(&1.app))

    unlock =
      for {app, _} <- old_lock,
          not Map.has_key?(lock, app),
        into: unlock,
        do: Atom.to_string(app)

    unlock =
      Enum.uniq(unlock)
      |> with_children(old_lock)
      |> Enum.uniq

    for {name, app, vsn} <- Hex.Mix.from_lock(old_lock),
        not app in unlock,
        do: {name, app, vsn}
  end
end
