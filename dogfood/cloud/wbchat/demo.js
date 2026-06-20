// wbchat/demo — NOT a component; a demo seed.
// demoMessages() returns an array of message objects exercising EVERY registered part type,
// so the library can be visually verified end-to-end. No registration, no side effects.
// Message shape (per core.js): { id, role:'user'|'assistant', parts:[{type, ...}] }

export function demoMessages() {
  return [
    {
      id: 'demo-user-1',
      role: 'user',
      parts: [{ type: 'text', text: 'Give me a quick summary and a plan.' }],
    },
    {
      id: 'demo-assistant-1',
      role: 'assistant',
      parts: [
        { type: 'reasoning', text: 'Let me think… the user wants a summary.', duration: 3 },
        { type: 'text', text: 'Here is a **markdown** summary with a list:\n- one\n- two' },
        { type: 'code', lang: 'work', code: [
          'data :tasks do',
          '  field :title, :string',
          '  field :done, :bool, default: false',
          'end',
          '',
          'server :complete do',
          '  def run(id) do',
          '    Tasks.get(id)',
          '    |> Map.put(:done, true)',
          '    |> Tasks.save()',
          '  end',
          'end',
          '',
          'client :list do',
          '  for t <- @tasks do',
          '    li t.title, checked: t.done',
          '  end',
          'end',
        ].join('\n') },
        { type: 'code', lang: 'js', code: 'export const x = () => 42;' },
        { type: 'tool', name: 'search_web', state: 'complete', input: { q: 'workbooks' }, output: '3 results' },
        { type: 'sources', sources: [{ title: 'Workbooks docs', url: 'https://docs.workbooks.sh' }] },
        { type: 'task', title: 'Plan', items: [{ label: 'Scaffold', status: 'done' }, { label: 'Deploy', status: 'active' }] },
        { type: 'image', url: 'https://placehold.co/300x160', alt: 'a generated image' },
        { type: 'suggestions', suggestions: ['Tell me more', 'Deploy it'] },
      ],
    },
  ];
}
