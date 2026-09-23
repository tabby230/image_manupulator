import sys

path = '/home/aravind-inc5850/Desktop/image_manipulator/lib/image_manipulator_web/live/studio_live.ex'

with open(path, 'r') as f:
    content = f.read()

# 1. Remove put_flash from apply_changes error
content = content.replace(
    '          {:error, reason} ->\n            {:noreply,\n             socket\n             |> assign(processing: nil, error: reason)\n             |> put_flash(:error, "Unable to process image.")}',
    '          {:error, reason} ->\n            {:noreply,\n             socket\n             |> assign(processing: nil, error: reason)}'
)

# 2. Remove put_flash from save_output error
content = content.replace(
    '          {:error, reason} ->\n            {:noreply,\n             socket\n             |> assign(save_form: save_form, save_error: reason)\n             |> put_flash(:error, "Unable to save image.")}',
    '          {:error, reason} ->\n            {:noreply,\n             socket\n             |> assign(save_form: save_form, save_error: reason)}'
)

# 3. Remove put_flash from save_settings error
content = content.replace(
    '      {:error, reason} ->\n        {:noreply,\n         socket\n         |> assign(settings_error: reason)\n         |> put_flash(:error, "Could not save settings.")}',
    '      {:error, reason} ->\n        {:noreply,\n         socket\n         |> assign(settings_error: reason)}'
)

# 4. Remove put_flash from reset_settings
content = content.replace(
    '    {:noreply,\n     socket\n     |> assign_settings(settings, false)\n     |> put_flash(:info, "Settings restored to defaults.")}\n  end',
    '    {:noreply,\n     socket\n     |> assign_settings(settings, false)}\n  end'
)

# 5. Remove put_flash from finish_apply
content = content.replace(
    '    |> refresh_session_usage()\n    |> put_flash(\n      :info,\n      "✓ Changes applied successfully — #{length(decorated)} file(s) written to the session workspace."\n    )\n  end',
    '    |> refresh_session_usage()\n  end'
)

# 6. Remove put_flash from write_output error
content = content.replace(
    '      {:error, reason} ->\n        {:noreply,\n         socket\n         |> assign(save_error: reason)\n         |> put_flash(:error, "Unable to save image.")}',
    '      {:error, reason} ->\n        {:noreply,\n         socket\n         |> assign(save_error: reason)}'
)

# 7. Add delete_image handler after delete_upload handler
old = '      {:error, reason} ->\n        {:noreply, put_error(socket, reason)}\n    end\n  end\n\n  # ---------------------------------------------------------------------------\n  # Image operations'

new = '''      {:error, reason} ->
        {:noreply, put_error(socket, reason)}
    end
  end

  @impl true
  def handle_event("delete_image", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.saved_images, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      entry ->
        case Workspace.remove(entry.path) do
          :ok ->
            saved_images = Enum.reject(socket.assigns.saved_images, &(&1.id == id))
            {:noreply,
             socket
             |> assign(saved_images: saved_images)
             |> put_flash(:info, "Image removed.")}

          {:error, reason} ->
            {:noreply, put_error(socket, reason)}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Image operations'''

content = content.replace(old, new)

with open(path, 'w') as f:
    f.write(content)

print("Done!")
