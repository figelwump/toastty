import type { ChatProject, ChatState } from "./types";

interface ProjectReference {
  project: string | null;
  projectID?: string | null;
}

/// Older state fixtures name projects only by title. Current app state
/// always supplies the ID, including null for a task with no project.
export function projectID(value: ProjectReference): string | null {
  return value.projectID === undefined ? value.project : value.projectID;
}

export function projectsFor(state: ChatState): ChatProject[] {
  if (state.projects) return state.projects;
  const projects = new Map<string, ChatProject>();
  for (const row of state.tasks ?? []) {
    const id = projectID(row);
    if (id !== null && typeof row.project === "string" && !projects.has(id)) projects.set(id, { id, title: row.project });
  }
  return [...projects.values()].sort((a, b) => a.title.localeCompare(b.title) || a.id.localeCompare(b.id));
}

export function currentProject(state: ChatState, requested = state.projectFilter ?? null): string | null {
  return requested !== null && projectsFor(state).some((project) => project.id === requested) ? requested : null;
}

export function projectTitle(state: ChatState, id = currentProject(state)): string {
  return projectsFor(state).find((project) => project.id === id)?.title ?? "All projects";
}
