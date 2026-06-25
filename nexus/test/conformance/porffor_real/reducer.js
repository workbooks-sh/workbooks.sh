const reducer = (state, action) => {
  switch (action.type) {
    case 'inc': return {...state, count: state.count + (action.by ?? 1)};
    case 'reset': return {...state, count: 0};
    default: return state;
  }
};
let s = {count: 0, name: 'x'};
for (const a of [{type:'inc'},{type:'inc',by:5},{type:'reset'},{type:'inc',by:3}]) s = reducer(s, a);
console.log(s.count, s.name);
