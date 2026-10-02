alias VideoTool.Repo
import Ecto.Query
Repo.all(from s in "series", select: {s.id, s.name, s.channel_slug})
|> Enum.each(fn {id, name, slug} -> IO.puts("#{id}\t#{name}\t#{slug}") end)
